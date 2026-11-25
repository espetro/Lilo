#!/usr/bin/env python3
"""Tests the containerized MCP surface end to end: builds nothing itself, runs
the image `docker-mcp-test` built and drives it over stdio as an MCP client.

  python3 -I container/linux/mcp_container_test.py <docker|podman> <image>

Checks the handshake, the tool listing, tab creation, navigation to a data:
URL, a read_page with an element, and a click. Exits non-zero on the first
mismatch; every failure line says what was expected.
"""

import json
import subprocess
import sys
import threading
import time


class Client:
    """Speaks MCP over the container's stdio."""

    def __init__(self, docker, image):
        # ALLOW_ALL: an unattended container has no consent surface to answer
        # in; a [needs_user] failure with a missing prompt would fail here.
        self.process = subprocess.Popen(
            [docker, "run", "-i", "--rm",
             "-e", "LILO_AGENT_ALLOW_ALL=1", image],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)
        self.replies = {}
        self.pending = []
        self.lock = threading.Lock()
        self.next_id = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if "id" in message:
                with self.lock:
                    self.replies[message["id"]] = message
            else:
                with self.lock:
                    self.pending.append(message)

    def request(self, method, params=None, timeout=120):
        with self.lock:
            self.next_id += 1
            request_id = self.next_id
        line = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method,
                           "params": params or {}})
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                reply = self.replies.pop(request_id, None)
            if reply is not None:
                return reply
            time.sleep(0.05)
        raise TimeoutError(f"{method} got no reply within {timeout} s")

    def notify(self, method, params=None):
        line = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}})
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        except Exception:  # noqa: BLE001 - the reader thread outlives the pipe
            self.process.kill()


def tool_call(client, name, arguments, timeout=120):
    reply = client.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)
    if reply.get("error"):
        raise AssertionError(f"{name} errored: {reply['error']}")
    text = "\n".join(part.get("text", "") for part in reply["result"].get("content", [])
                     if part.get("type") == "text")
    if reply["result"].get("isError"):
        raise AssertionError(f"{name} failed: {text}")
    return text


def main():
    docker, image = sys.argv[1], sys.argv[2]
    client = Client(docker, image)
    try:
        reply = client.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "lilo-container-test", "version": "1"}})
        server = reply["result"]["serverInfo"]
        assert server["name"] == "lilo", f"server name was {server}"
        client.notify("notifications/initialized")

        reply = client.request("tools/list")
        names = {tool["name"] for tool in reply["result"]["tools"]}
        expected = {"tabs_context_mcp", "tabs_create_mcp", "tabs_close_mcp", "navigate", "read_page",
                    "find", "wait_for", "get_page_text", "form_input", "javascript_tool", "computer",
                    "resize_window", "browser_config", "connect_status", "browser_batch"}
        missing = expected - names
        assert not missing, f"tools/list is missing: {sorted(missing)}"

        text = tool_call(client, "tabs_context_mcp", {"createIfEmpty": True, "title": "Container test"})
        tab_id = int(json.loads(text)["availableTabs"][0]["tabId"])

        page = ("data:text/html,<h1 id=t>Lilo container</h1>"
                "<input id=q placeholder=Search><button id=b>Go</button>")
        text = tool_call(client, "navigate", {"tabId": tab_id, "url": page})
        assert "Lilo container" in text, f"navigate reply did not show the page: {text}"

        text = tool_call(client, "read_page", {"tabId": tab_id, "filter": "interactive"})
        assert "ref_" in text, f"read_page gave no refs: {text}"
        assert "Go" in text, f"read_page missed the button: {text}"

        text = tool_call(client, "find", {"tabId": tab_id, "query": "go"})
        assert "ref_" in text, f"find gave no refs: {text}"

        text = tool_call(client, "get_page_text", {"tabId": tab_id})
        assert "Lilo container" in text, f"get_page_text missed the heading: {text}"

        text = tool_call(client, "form_input", {"tabId": tab_id, "ref": "ref_1", "value": "hello"})
        assert "hello" in text, f"form_input reply: {text}"

        text = tool_call(client, "computer", {"tabId": tab_id, "action": "left_click", "ref": "ref_2"})
        assert "ref_2" in text or "Clicked" in text, f"computer click reply: {text}"

        text = tool_call(client, "javascript_tool", {"tabId": tab_id, "text": "document.title"})
        assert text.strip(), f"javascript_tool gave no title: {text!r}"

        text = tool_call(client, "browser_config", {})
        config = json.loads(text)
        assert config["lilo"] == "container", f"browser_config version: {config}"

        print("containerized MCP surface: all checks passed")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
