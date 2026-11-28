#!/usr/bin/env python3
"""Measures the MCP layer Lilo serves, not agent quality: the initialize and tools/list handshake cost, the
tools/list schema tax every turn pays, and per-tool-call latency and payload size. It talks JSON-RPC over
stdio to a `lilo-mcp` bridge directly: no agent CLI, no API key, no dataset.

Safe against a live Lilo: it only creates agent tabs on a data: URL and closes them again, never the user's
tabs or real sites. The first run asks Lilo's usual consent prompt for the "lilo-probe" client; answer it once.

  python3 -I bench/mcp/probe.py [--bridge PATH] [--reps 5] [--concurrency 1,4,8] [--timeout 90]
"""

import argparse
import datetime
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_BRIDGE = os.environ.get("LILO_MCP", "/Applications/Lilo.app/Contents/MacOS/lilo-mcp")
# A small static page: enough DOM for read_page and a screenshot, nothing that loads or runs long.
PAGE = "data:text/html," + urllib.parse.quote(
    "<title>probe</title><h1>Probe</h1><button>Go</button><p>" + "lorem ipsum " * 20 + "</p>")
TOOLS = ["tabs_context_mcp", "tabs_create_mcp", "navigate", "read_page", "computer", "tabs_close_mcp"]


class BridgeError(Exception):
    pass


class Session:
    """One `lilo-mcp` process: newline-delimited JSON-RPC 2.0 on its stdin/stdout."""

    def __init__(self, bridge):
        try:
            self.proc = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True, bufsize=1)
        except OSError as error:
            raise BridgeError(f"cannot start {bridge}: {error}") from error
        self.lines = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, message):
        try:
            self.proc.stdin.write(json.dumps(message) + "\n")
            self.proc.stdin.flush()
        except (OSError, ValueError) as error:
            raise BridgeError(f"the bridge closed its stdin: {error}") from error

    def call(self, method, params=None, timeout=90):
        """(response, raw reply line) for one request; BridgeError or TimeoutError on failure."""
        self.next_id += 1
        request_id = self.next_id
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(deadline - time.monotonic(), 0.001))
            except queue.Empty:
                raise TimeoutError(f"{method} got no reply within {timeout} s")
            if line is None:
                raise BridgeError("the bridge closed its stdout")
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("method") and "id" in message:
                # Lilo asking the client something (roots/list): the probe serves no requests.
                self.send({"jsonrpc": "2.0", "id": message["id"],
                           "error": {"code": -32601, "message": "the probe serves no requests"}})
            elif message.get("id") == request_id and ("result" in message or "error" in message):
                return message, line

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def est_tokens(text):
    """A rough token count: chars/4."""
    return len(text) // 4


def percentile(values, q):
    """Nearest-rank percentile of `values`; None when empty."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, -(-q * len(ordered) // 100) - 1)]


def ms_summary(samples):
    """samples of (seconds, bytes, failed): p50/p90/max in ms over the calls that did not fail, plus errors."""
    ok = [seconds for seconds, _, failed in samples if not failed]
    stats = {key: percentile(ok, q) for key, q in (("p50", 50), ("p90", 90))}
    return {"p50_ms": round(1000 * (stats["p50"] or 0), 1),
            "p90_ms": round(1000 * (stats["p90"] or 0), 1),
            "max_ms": round(1000 * max(ok), 1) if ok else 0.0,
            "errors": len(samples) - len(ok)}


def tools_summary(result, raw):
    """The tools/list payload: bytes and est. tokens on the wire, and each tool's description length, longest first."""
    return {"bytes": len(raw.encode()), "est_tokens": est_tokens(raw),
            "tools": sorted(({"name": t.get("name", "?"), "description_chars": len(t.get("description") or "")}
                             for t in result.get("tools") or []), key=lambda t: -t["description_chars"])}


def record(session, samples, name, arguments, timeout):
    """One timed tools/call appended to samples[name] as (seconds, bytes, failed); its result, or None on failure."""
    started = time.monotonic()
    try:
        message, raw = session.call("tools/call", {"name": name, "arguments": arguments}, timeout)
    except (BridgeError, TimeoutError):
        samples[name].append((time.monotonic() - started, 0, True))
        return None
    result = message.get("result") or {}
    samples[name].append((time.monotonic() - started, len(raw.encode()), bool(result.get("isError"))))
    return result


def flatten(content):
    return "\n".join(part.get("text", "") for part in content or [] if part.get("type") == "text")


def worker(bridge, reps, timeout):
    """One bridge process: the handshake, then `reps` rounds of context/create/navigate/read/screenshot/close."""
    session = Session(bridge)
    try:
        clock = time.monotonic()
        init, _ = session.call("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "lilo-probe", "version": "0"}}, timeout)
        init_s = time.monotonic() - clock
        if "error" in init:
            raise BridgeError(f"initialize failed: {init['error'].get('message')}")
        session.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        clock = time.monotonic()
        listing, list_raw = session.call("tools/list", timeout=timeout)
        list_s = time.monotonic() - clock
        if "error" in listing:
            raise BridgeError(f"tools/list failed: {listing['error'].get('message')}")
        result = listing.get("result") or {}
        if not result.get("tools"):
            instructions = ((init.get("result") or {}).get("instructions") or "")
            raise BridgeError("the bridge answered on its own, tools/list is empty: "
                              + (instructions or "Lilo is not accepting agents (Settings > AI agents)."))
        samples = {name: [] for name in TOOLS}
        # Consent check: the first tool call is what makes Lilo ask the user; fail fast on the answer.
        warmup = record(session, samples, "tabs_context_mcp", {}, timeout)
        text = flatten((warmup or {}).get("content"))
        if "[needs_user]" in text:
            raise BridgeError(f"Lilo is waiting for the user to allow this agent: {text[:200]}")
        for _ in range(reps):
            tab_id = None
            result = record(session, samples, "tabs_context_mcp", {}, timeout)
            result = record(session, samples, "tabs_create_mcp", {"title": "probe"}, timeout) or result
            match = re.search(r"Tab ID: (\d+)", flatten((result or {}).get("content")))
            if match:
                tab_id = int(match.group(1))
                for name, arguments in (("navigate", {"url": PAGE, "tabId": tab_id}),
                                        ("read_page", {"tabId": tab_id, "filter": "interactive"}),
                                        ("computer", {"action": "screenshot", "tabId": tab_id})):
                    record(session, samples, name, arguments, timeout)
            if tab_id is not None:
                record(session, samples, "tabs_close_mcp", {"tabId": tab_id}, timeout)
        return {"init_s": init_s, "list_s": list_s, "list_raw": list_raw,
                "list_result": listing.get("result") or {},
                "app": ((init.get("result") or {}).get("serverInfo") or {}).get("version"),
                "samples": samples}
    finally:
        session.close()


def spawn(bridge, concurrency, reps, timeout):
    """`concurrency` workers at once; ("ok", worker result) or ("error", exception) per worker."""
    out = []

    def job():
        try:
            out.append(("ok", worker(bridge, reps, timeout)))
        except Exception as error:  # noqa: BLE001 - reported to the user, one bad worker fails the level
            out.append(("error", error))

    threads = [threading.Thread(target=job, daemon=True) for _ in range(concurrency)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return out


def report_level(out, results, concurrency, reps, bridge, started):
    errors = [(kind, error) for kind, error in results if kind == "error"]
    if errors:
        for _, error in errors:
            print(f"probe: {error}", file=sys.stderr)
        sys.exit(1)
    runs = [result for kind, result in results]
    app = next((r["app"] for r in runs if r["app"]), None)
    base = {"probe": "mcp", "bridge": str(bridge), "app_version": app, "started": started,
            "concurrency": concurrency}
    init_stats = ms_summary([(r["init_s"], 0, False) for r in runs])
    list_stats = ms_summary([(r["list_s"], 0, False) for r in runs])
    rows = [
        {**base, "kind": "initialize", "workers": concurrency, **init_stats},
        {**base, "kind": "tools_list", "workers": concurrency, **list_stats,
         **tools_summary(runs[0]["list_result"], runs[0]["list_raw"])},
    ]
    for name in TOOLS:
        pooled = [sample for r in runs for sample in r["samples"][name]]
        stats = ms_summary(pooled)
        bytes_ok = [nbytes for _, nbytes, failed in pooled if not failed and nbytes]
        rows.append({**base, "kind": "tool", "tool": name, "reps": reps, "workers": concurrency,
                     "samples": len(pooled), "result_bytes_mean":
                     round(sum(bytes_ok) / len(bytes_ok)) if bytes_ok else 0, **stats})
    with out.open("a") as file:
        for row in rows:
            file.write(json.dumps(row) + "\n")
    summary = runs[0]["list_result"]
    listing = tools_summary(summary, runs[0]["list_raw"])
    print(f"[{concurrency} bridge{'s' if concurrency > 1 else ''}] initialize p50 {init_stats['p50_ms']} ms "
          f"p90 {init_stats['p90_ms']} max {init_stats['max_ms']}; tools/list p50 {list_stats['p50_ms']} ms, "
          f"{listing['bytes']} bytes (~{listing['est_tokens']} tokens), {len(listing['tools'])} tools")
    for row in rows[2:]:
        print(f"  {row['tool']:<18} p50 {row['p50_ms']:>8} ms  p90 {row['p90_ms']:>8} ms  "
              f"max {row['max_ms']:>8} ms  ~{row['result_bytes_mean']:>7} B  errors {row['errors']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bridge", default=DEFAULT_BRIDGE, help="lilo-mcp binary (default: $LILO_MCP or the app)")
    parser.add_argument("--reps", type=int, default=5, help="rounds of the call set per bridge process")
    parser.add_argument("--concurrency", default="1", help="comma-separated bridge process counts, e.g. 1,4,8")
    parser.add_argument("--timeout", type=int, default=90, help="seconds per call, the bridge's own limit")
    parser.add_argument("--out", help="JSONL results (default results/probe-<timestamp>.jsonl)")
    args = parser.parse_args()
    try:
        levels = [int(x) for x in args.concurrency.split(",")]
    except ValueError:
        sys.exit("--concurrency takes comma-separated integers, e.g. 1,4,8")
    if not levels or min(levels) < 1 or args.reps < 1:
        sys.exit("--concurrency and --reps must be positive")
    bridge = Path(args.bridge).expanduser()
    if not os.access(bridge, os.X_OK):
        sys.exit(f"no runnable bridge at {bridge}: pass --bridge or set LILO_MCP "
                 "(make install-debug puts it in the Debug app's bundle)")
    started = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = Path(args.out) if args.out else HERE / "results" / f"probe-{started.replace(':', '')}.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    for level in levels:
        report_level(out, spawn(str(bridge), level, args.reps, args.timeout), level, args.reps,
                     str(bridge), started)
    print(f"results: {out}")


if __name__ == "__main__":
    main()
