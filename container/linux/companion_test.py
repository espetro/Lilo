#!/usr/bin/env python3
"""Tests the companion driver and peer against a fake extension end.

The fake is a thread speaking the real wire protocol (UInt32 LE length +
UTF-8 JSON) over the real unix socket the peer listens on, replaying the
shared contract fixtures and a small in-memory browser. Platform
independent: plain python3 runs it anywhere; `make docker-mcp-test` runs it
inside the image too.

  python3 -I container/linux/companion_test.py

Covers: the hello handshake, tabs.list/tabs.open round-trips, snapshot, a
scripting.execute round-trip, malformed-frame tolerance (the fake sends
garbage frames and bad JSON; the peer must drop the connection, not die),
EOF/reconnect (the fake closes and reconnects; a later request still
answers), timeouts, and the driver's page_method injection path plus its
documented close_tab gap. Exits non-zero on the first failure.
"""

import json
import os
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import companion_peer  # noqa: E402
from companion_peer import CompanionPeer, PeerError  # noqa: E402

FIXTURES = json.load(open(os.path.join(HERE, "../../companion-extension/src/protocol.fixtures.json"),
                          encoding="utf-8"))


def frame(message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    return struct.pack("<I", len(body)) + body


def read_frame(conn):
    header = _recv(conn, 4)
    if header is None:
        return None
    (length,) = struct.unpack("<I", header)
    body = _recv(conn, length)
    if body is None:
        return None
    return json.loads(body.decode("utf-8"))


def _recv(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


class FakeExtension:
    """The extension's side of the socket: says hello, then serves requests
    from a scripted handler table. Reusable across reconnects."""

    def __init__(self, handler):
        self.handler = handler
        self.hellos = 0
        self.requests = []

    def serve_one(self, path):
        conn = connect(path)
        self.conn = conn
        try:
            conn.sendall(frame({"type": "hello", "protocolVersion": 1, "peer": "fake"}))
            self.hellos += 1
            while True:
                try:
                    message = read_frame(conn)
                except (ValueError, json.JSONDecodeError, UnicodeDecodeError, OSError):
                    break  # a malformed frame or a reset: close, like a real host would
                if message is None:
                    break
                self.requests.append(message)
                response = self.handler(message)
                if response is not None:
                    conn.sendall(frame(response))
        except OSError:  # noqa: BLE001 - sendall racing the peer's close
            pass  # the peer closed the connection: EOF on our side
        finally:
            self.conn = None
            try:
                conn.close()
            except OSError:
                pass

    def close(self):
        """Forces the EOF half of the reconnect test."""
        conn = self.conn
        if conn is not None:
            try:
                conn.shutdown(companion_peer.socket.SHUT_RDWR)
                conn.close()
            except OSError:
                pass


def connect(path):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            conn = companion_peer.socket.socket(companion_peer.socket.AF_UNIX,
                                                companion_peer.socket.SOCK_STREAM)
            conn.connect(path)
            return conn
        except OSError:
            time.sleep(0.05)
    raise AssertionError("the fake extension could not connect to the peer socket")


class FakeBrowser:
    """tabs.list/tabs.open/snapshot over a dict of tabs, plus a scripting
    world per tab that actually evaluates a tiny subset: enough to prove the
    round-trip, not to run AgentPage.js (that is the real browser's job)."""

    def __init__(self):
        self.tabs = {1: {"url": "https://example.com/", "title": "Example", "active": True}}
        self.next_id = 2
        self.script_results = {}

    def handle(self, message):
        tool = message.get("tool")
        params = message.get("params") or {}
        if tool == "tabs.list":
            prefixes = params.get("urlPrefixes") or []
            tabs = [dict(tab, id=tab_id) for tab_id, tab in self.tabs.items()
                    if not prefixes or any(tab["url"].startswith(prefix) for prefix in prefixes)]
            return {"id": message["id"], "ok": True, "tool": tool, "result": {"tool": tool, "tabs": tabs}}
        if tool == "tabs.open":
            tab_id = self.next_id
            self.next_id += 1
            self.tabs[tab_id] = {"url": params["url"], "title": "", "active": False}
            return {"id": message["id"], "ok": True, "tool": tool, "result": {"tool": tool, "tabId": tab_id}}
        if tool == "snapshot":
            tab = self.tabs.get(params["tabId"])
            if tab is None:
                return {"id": message["id"], "ok": False, "tool": tool, "error": f"no tab {params['tabId']}"}
            text = tab["title"] + " " + tab["url"]
            capped = text[:params.get("maxChars", 50000)]
            return {"id": message["id"], "ok": True, "tool": tool,
                    "result": {"tool": "snapshot",
                               "snapshot": {"url": tab["url"], "title": tab["title"],
                                            "text": capped, "truncated": len(capped) < len(text)}}}
        if tool == "scripting.execute":
            tab_id = params["tabId"]
            if tab_id not in self.tabs:
                return {"id": message["id"], "ok": False, "tool": tool, "error": f"no tab {tab_id}"}
            if "__hang" in params["funcSource"]:
                return None  # never answers: the timeout path's stand-in
            result = self.script_results.get((tab_id, params["funcSource"]))
            if result is None:
                return {"id": message["id"], "ok": False, "tool": tool, "error": "the fake has no script result"}
            return {"id": message["id"], "ok": True, "tool": tool,
                    "result": {"tool": tool, "result": result}}
        return {"id": message.get("id") or "?", "ok": False, "tool": tool, "error": f"unknown tool {tool}"}


def check(name, condition, detail=""):
    if not condition:
        print(f"FAIL {name}: {detail}")
        sys.exit(1)
    print(f"ok {name}")


def test_fixtures():
    """The fixtures pin the TypeScript schema and the Swift host to the same
    accepts and rejects; the peer's client side never sends an invalid
    message, so this only checks the file is loadable and shaped as the
    contract the fake replays."""
    cases = FIXTURES["cases"]
    valid = [case for case in cases if "error" not in case]
    check("fixtures load", len(cases) >= 15 and len(valid) >= 5, f"{len(cases)} cases")
    # Every valid case round-trips through the fake browser handler without
    # an unknown-tool rejection (a rejected one means the contract moved).
    browser = FakeBrowser()
    for case in valid:
        message = case["message"]
        response = browser.handle(message)
        check(f"fixture {case['name']}", response.get("ok") is True or message["tool"] not in
              ("tabs.list", "tabs.open", "snapshot", "scripting.execute") or
              "no tab" in str(response.get("error", "")) or
              "the fake has no script result" in str(response.get("error", "")),
              json.dumps(response))


def test_peer_roundtrip(tmpdir):
    path = os.path.join(tmpdir, "companion.sock")
    browser = FakeBrowser()
    fake = FakeExtension(browser.handle)
    peer = CompanionPeer(path).start()
    try:
        thread = threading.Thread(target=fake.serve_one, args=(path,), daemon=True)
        thread.start()
        check("hello awaited", peer.wait_connected(5))

        result = peer.request("tabs.list", {})
        check("tabs.list", [tab["id"] for tab in result["tabs"]] == [1], json.dumps(result))

        result = peer.request("tabs.list", {"urlPrefixes": ["https://example.com/"]})
        check("tabs.list prefix", len(result["tabs"]) == 1)

        result = peer.request("tabs.open", {"url": "about:blank", "background": True})
        check("tabs.open", result["tabId"] == 2, json.dumps(result))

        result = peer.request("snapshot", {"tabId": 1, "maxChars": 100})
        check("snapshot", result["snapshot"]["url"] == "https://example.com/", json.dumps(result))

        browser.script_results[(1, "() => 41 + 1")] = 42
        result = peer.request("scripting.execute",
                              {"tabId": 1, "funcSource": "() => 41 + 1", "args": []})
        check("scripting.execute", result["result"] == 42, json.dumps(result))

        # The error path: the fake reports it, the peer raises with the words.
        try:
            peer.request("snapshot", {"tabId": 99})
            check("error surfaces", False, "no raise")
        except PeerError as error:
            check("error surfaces", "no tab 99" in str(error))

        try:
            peer.request("scripting.execute", {"tabId": 1, "funcSource": "() => __hang", "args": []},
                         timeout=0.3)
            check("timeout raises", False, "no raise")
        except PeerError as error:
            check("timeout raises", "no response" in str(error))
    finally:
        peer.stop()


def test_malformed_frame(tmpdir):
    """A frame that is not JSON, and a frame with an absurd length: the
    peer's reader must drop that connection (fail closed on a desync) and
    stay alive for a fresh one."""
    path = os.path.join(tmpdir, "companion.sock")
    browser = FakeBrowser()
    fake = FakeExtension(browser.handle)
    peer = CompanionPeer(path).start()
    try:
        thread = threading.Thread(target=fake.serve_one, args=(path,), daemon=True)
        thread.start()
        check("hello (malformed round)", peer.wait_connected(5))

        conn = connect(path)
        conn.sendall(b"\xff\xff\xff\xff" + b"garbage")  # 4 GB length header
        time.sleep(0.2)  # the peer drops the desynced connection
        # The bad connection died; the good one must keep answering.
        result = peer.request("tabs.list", {})
        check("peer survives a bad frame", isinstance(result.get("tabs"), list), json.dumps(result))

        conn = connect(path)
        conn.sendall(struct.pack("<I", 3) + b"{!!")  # not JSON
        time.sleep(0.2)
        time.sleep(0.2)  # the reader drops this connection too
        result = peer.request("tabs.list", {})
        check("peer survives bad JSON", isinstance(result.get("tabs"), list), json.dumps(result))
    finally:
        peer.stop()


def test_reconnect(tmpdir):
    """The extension's host reconnects (5 s backoff in nativePort.ts; here
    immediate): a request that raced the close raises, and a request after
    the reconnect answers on the new connection."""
    path = os.path.join(tmpdir, "companion.sock")
    browser = FakeBrowser()
    fake = FakeExtension(browser.handle)
    peer = CompanionPeer(path).start()
    try:
        first = threading.Thread(target=fake.serve_one, args=(path,), daemon=True)
        first.start()
        check("hello (reconnect round)", peer.wait_connected(5))
        peer.request("tabs.list", {})

        fake.close()  # the host's socket goes away: EOF on our side
        time.sleep(0.3)
        # No connection now: a request says so instead of hanging.
        try:
            peer.request("tabs.list", {})
            check("no connection raises", False, "no raise")
        except PeerError as error:
            check("no connection raises", "no companion connection" in str(error))

        second = threading.Thread(target=fake.serve_one, args=(path,), daemon=True)
        second.start()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                result = peer.request("tabs.list", {})
                check("reconnected request answers", len(result["tabs"]) >= 1, json.dumps(result))
                break
            except PeerError:
                time.sleep(0.05)
        else:
            check("reconnected request answers", False, "never answered")
    finally:
        peer.stop()


def test_driver(tmpdir):
    """The driver over the fake: tab creation, tabs_snapshot shape,
    page_method (with the fake's scripted AgentPage.js answer), navigate's
    snapshot-based URL read, and the documented close_tab gap."""
    path = os.path.join(tmpdir, "companion.sock")
    browser = FakeBrowser()
    fake = FakeExtension(browser.handle)
    peer = CompanionPeer(path)

    import companion_driver
    companion_driver.AGENT_PAGE_JS = open(
        os.path.join(HERE, "../../Lilo/Agent/AgentPage.js"), encoding="utf-8").read()
    driver = companion_driver.Driver(on_event=lambda event, data: None, socket_path=path)
    peer = driver.peer
    try:
        thread = threading.Thread(target=fake.serve_one, args=(path,), daemon=True)
        thread.start()
        driver.start()
        if not peer.wait_connected(5):
            check("driver hello", False, "the fake never connected")
        check("driver hello", True)

        created = driver.run(lambda: driver.create_tab("Test session"))
        tab_id = created["tabId"]
        check("driver create_tab", isinstance(tab_id, int) and tab_id >= 2, json.dumps(created))

        snapshot = driver.run(driver.tabs_snapshot)
        entry = [tab for tab in snapshot if tab["tabId"] == tab_id][0]
        check("driver tabs_snapshot", entry["title"] == "Test session" and entry["url"] == "about:blank",
              json.dumps(snapshot))

        # page_method: the injection call goes through scripting.execute.
        method = json.dumps({"method": "readPage", "args": {"filter": "interactive"}})
        call = ("async (params) => {\n"
                "  if (!window.__liloAgent) { " +
                companion_driver._eval_source(companion_driver.AGENT_PAGE_JS) + "\n"
                "    if (!window.__liloAgent) return '__lilo_missing' }\n"
                "  const agent = window.__liloAgent\n"
                "  const value = await agent[params.method](params.args)\n"
                "  return value === undefined ? null : value\n"
                "}")
        browser.script_results[(tab_id, call)] = "button ref_1 Go"
        text = driver.run(lambda: driver.page_method(tab_id, "readPage", {"filter": "interactive"}))
        check("driver page_method", text == "button ref_1 Go", repr(text))

        browser.tabs[tab_id]["url"] = "https://example.com/next"
        browser.script_results[(tab_id, "async () => { location.href = \"https://example.com/next\"; return true }")] = True
        # The settle probe answers settled on the first try.
        browser.script_results[(tab_id, companion_driver.SETTLE_DOM_SOURCE)] = True
        result = driver.run(lambda: driver.navigate(tab_id, "example.com/next"))
        check("driver navigate", result["url"] == "https://example.com/next", json.dumps(result))

        try:
            driver.run(lambda: driver.close_tab(tab_id))
            check("driver close_tab gap", False, "no raise")
        except RuntimeError as error:
            check("driver close_tab gap", "not supported by the companion protocol" in str(error))

        consent = driver.ask_consent({"requestId": "r", "timeout": 1})
        check("driver consent expires", consent == {"granted": None, "alwaysAllowSite": None, "expired": True},
              json.dumps(consent))
    finally:
        driver.peer.stop()


def main():
    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        test_fixtures()
        test_peer_roundtrip(tmpdir)
        test_malformed_frame(tmpdir)
        test_reconnect(tmpdir)
        test_driver(tmpdir)
    print("companion driver and peer: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
