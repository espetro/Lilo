#!/usr/bin/env python3
"""Run check groups quietly and report one line each, so a gate costs an agent few tokens.

    check_summary.py run NAME LOGDIR -- COMMAND...   run COMMAND, its output to LOGDIR/NAME.log, the result to LOGDIR/NAME.json
    check_summary.py report [--json] LOGDIR NAME...  print the result of each NAME; exit 1 when any failed

The report prints `ok  NAME 1.2s` or `FAIL NAME 1.2s` per check, then the full log of the failed checks only,
then a line counting the bytes printed above it (what an agent pays to read the report). With --json it prints
one object per check instead: check, ok, dur_s, bytes (the log's size) and, when it failed, log_tail (its last 20 lines).

When `make metrics-on` is active, `run` also writes one record per check (phase "check") to the metrics file
beside the recipe records, which `metrics.py summary` ignores. Optional fields come from the environment:
LILO_CHECK_TIER, LILO_CHECK_TRIGGER and LILO_CHECK_SCOPE; `rerun_of` is the `ts` of this check's previous failed
record in the same worktree and branch, when the one before this run failed. See docs/build-baseline.md.
"""
import json
import os
import subprocess
import sys
import time

import metrics

TAIL_LINES = 20
# How far back in the metrics file to look for the previous run of a check: a read of this size costs well under a millisecond.
LOOKBACK_BYTES = 256 * 1024
OPTIONAL = {"tier": "LILO_CHECK_TIER", "trigger": "LILO_CHECK_TRIGGER", "scope": "LILO_CHECK_SCOPE"}


def paths(logdir, name):
    return os.path.join(logdir, f"{name}.log"), os.path.join(logdir, f"{name}.json")


def previous_failure(record):
    """The ts of the last record of this check in this worktree and branch, when that run failed."""
    try:
        with open(metrics.metrics_file(), "rb") as file:
            file.seek(0, os.SEEK_END)
            file.seek(max(file.tell() - LOOKBACK_BYTES, 0))
            lines = file.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            last = json.loads(line)
        except ValueError:
            continue
        if (last.get("phase"), last.get("target"), last.get("worktree"), last.get("branch")) == \
                ("check", record["target"], record["worktree"], record["branch"]):
            return last["ts"] if last.get("exit") != 0 else None
    return None


def run(name, logdir, command):
    """Run COMMAND quietly. Returns its exit status."""
    log, result = paths(logdir, name)
    # LILO_METRICS_DIRTY is what metrics.py hands the recipes it wraps: it is set when, and only when, metrics are on.
    recording = "LILO_METRICS_DIRTY" in os.environ
    record = None
    if recording:
        begin = time.perf_counter()
        record = metrics.start_record(name, "check")
        record.update({field: os.environ[variable] for field, variable in OPTIONAL.items() if os.environ.get(variable)})
        rerun = previous_failure(record)
        if rerun:
            record["rerun_of"] = rerun
        overhead = time.perf_counter() - begin
    started = time.perf_counter()
    with open(log, "wb") as output:
        try:
            code = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT).returncode
        except OSError as error:
            output.write(f"{command[0]}: {error}\n".encode())
            code = 127
    duration = round(time.perf_counter() - started, 1)
    code = 128 - code if code < 0 else code
    metrics.write_atomically(result, json.dumps({"check": name, "ok": code == 0, "dur_s": duration, "bytes": os.path.getsize(log)}))
    if recording:
        try:
            metrics.append(metrics.finish_record(record, started, code, overhead))
        except OSError:
            pass  # a full disk must not fail the gate
    return code


def read_result(logdir, name):
    log, result = paths(logdir, name)
    try:
        with open(result, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        return {"check": name, "ok": False, "dur_s": 0.0, "bytes": os.path.getsize(log) if os.path.exists(log) else 0}


def read_log(logdir, name):
    try:
        with open(paths(logdir, name)[0], encoding="utf-8", errors="replace") as file:
            return file.read()
    except OSError:
        return ""


def report(logdir, names, as_json=False, out=None):
    """Print the results. Returns 1 when any check failed."""
    out = out or sys.stdout
    results = [read_result(logdir, name) for name in names]
    failed = [r for r in results if not r["ok"]]
    if as_json:
        for result in results:
            if not result["ok"]:
                result["log_tail"] = "\n".join(read_log(logdir, result["check"]).splitlines()[-TAIL_LINES:])
            print(json.dumps(result, separators=(",", ":")), file=out)
        return 1 if failed else 0
    text = "".join(f"{'ok ' if r['ok'] else 'FAIL'} {r['check']} {r['dur_s']:.1f}s\n" for r in results)
    for result in failed:
        log = read_log(logdir, result["check"])
        text += f"\n== {result['check']} ==\n{log}" + ("" if log.endswith("\n") or not log else "\n")
    out.write(text)
    print(f"{len(results)} checks, {len(failed)} failed, {len(text.encode())} bytes printed above", file=out)
    return 1 if failed else 0


def main(argv):
    if argv[:1] == ["run"] and len(argv) > 4 and argv[3] == "--":
        return run(argv[1], argv[2], argv[4:])
    if argv[:1] == ["report"]:
        rest = [a for a in argv[1:] if a != "--json"]
        if len(rest) >= 2:
            return report(rest[0], rest[1:], "--json" in argv)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
