#!/usr/bin/env python3
"""The companion-backed driver of Lilo's containerized MCP surface.

Same seam as ``driver.py`` (the WebKitGTK one), but the browser is the user's
real Chromium: the companion extension (``companion-extension/``) exposes its
tabs and pages over the framed unix-socket protocol this module's peer
(``companion_peer.py``) speaks. ``mcp_server.py`` picks this driver with
``LILO_DRIVER=companion``.

What it implements, per tool need, mirroring ``driver.py``:
  - tab bookkeeping (create/close/list) through ``tabs.list``/``tabs.open``:
    tab ids are the browser's own, discovered on demand
  - ``AgentPage.js`` method calls (readPage, find, waitFor, ...) through
    ``scripting.execute`` in the page's persistent isolated world — the same
    injection-once-then-call pattern ``driver.py`` uses with the
    "lilo-agent" world, minus subframes (scripting targets the main frame)
  - navigation by opening... no: by evaluating ``location`` in the page, with
    a DOM-quiet settle, since the extension has no navigate tool
  - synthetic input through AgentPage.js's ``act``/``scrollBy``, the same DOM
    event route ``driver.py`` takes
  - consent: unlike the WebKitGTK driver there is no chrome surface here, so
    every question expires immediately and the MCP server reports
    [needs_user] (or the operator sets LILO_AGENT_ALLOW_ALL=1)

Documented gaps vs the WebKitGTK driver (all honest approximations, none
silent): no screenshot (the extension cannot capture a tab), no
resize_window, no cross-origin subframe access in page methods, no
network-quiet settle half, and tabs_close is best-effort (the protocol has
no tabs.close tool; the page's window.close() only works for
script-openable pages, so closing usually fails with a clear ToolError).
"""

import json
import os
import threading
import time

import companion_peer
from companion_peer import PeerError

AGENT_PAGE_JS = open(os.environ.get("LILO_AGENT_PAGE", "/app/Lilo/Agent/AgentPage.js"),
                     encoding="utf-8").read()
WORLD = "lilo-agent"

SETTLE_QUIET_DOM_MS = 200
# The settle of AgentPageCore.waitForLoad, DOM half: the extension gives us no
# network activity signal either (documented approximation, as in driver.py).
SETTLE_DOM_SOURCE = """async (quietMs, maxMs) => {
  return await new Promise(resolve => {
    let quiet
    const done = settled => { observer.disconnect(); clearTimeout(quiet); clearTimeout(cap); resolve(settled) }
    const wait = () => { clearTimeout(quiet); quiet = setTimeout(() => done(document.readyState === 'complete'), quietMs) }
    const observer = new MutationObserver(wait)
    observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true })
    const cap = setTimeout(() => done(false), maxMs)
    wait()
  })
}"""


class Driver:
    """Owns the peer, the known tabs and nothing else: no event loop, calls
    run on the caller's thread (``run`` is identity, kept for interface
    parity with the WebKitGTK driver)."""

    def __init__(self, on_event=None, socket_path=None):
        self.on_event = on_event or (lambda event, data: None)
        self.peer = companion_peer.CompanionPeer(socket_path)
        self.tabs = {}  # tab_id -> {"title": str} — the browser owns the rest
        self._lock = threading.Lock()
        self._loop_thread = None  # parity with driver.run's inline check

    def start(self, on_idle=None):
        self.peer.start()
        self._loop_thread = threading.current_thread()
        if on_idle:
            on_idle()

    def run(self, fn, timeout=60.0):
        """Interface parity: the companion driver has no dedicated loop
        thread, so calls run inline. Exceptions propagate as raised — the
        MCP server reports them, and unlike Gtk there is no abort risk."""
        return fn()

    # -- tab operations ------------------------------------------------------

    def tabs_snapshot(self):
        try:
            result = self.peer.request("tabs.list", {}, timeout=15.0)
        except PeerError:
            return []
        tabs = []
        for tab in result.get("tabs", []):
            tab_id = tab.get("id")
            if not isinstance(tab_id, int):
                continue
            with self._lock:
                title = self.tabs.get(tab_id, {}).get("title")
            tabs.append({"tabId": tab_id, "title": title or tab.get("title") or "",
                         "url": tab.get("url") or ""})
        return tabs

    def create_tab(self, title):
        # No blank tab can be opened without a URL, so the tab starts at
        # about:blank — the same first page the WebKitGTK driver gives.
        result = self.peer.request("tabs.open", {"url": "about:blank", "background": True},
                                   timeout=15.0)
        tab_id = result.get("tabId")
        if not isinstance(tab_id, int):
            raise RuntimeError(f"tabs.open returned {result!r}")
        with self._lock:
            self.tabs[tab_id] = {"id": tab_id, "title": title or "Agent"}
        return {"tabId": tab_id}

    def tab(self, tab_id):
        if tab_id not in self.tabs:
            # A tab we never opened (the session was handed it) is still
            # addressable: the browser owns the ids, we only cache titles.
            known = [t["tabId"] for t in self.tabs_snapshot()]
            if tab_id not in known:
                raise KeyError(f"No tab {tab_id}")
            with self._lock:
                self.tabs[tab_id] = {"id": tab_id, "title": "Agent"}
        return self.tabs[tab_id]

    def close_tab(self, tab_id):
        """Best-effort: the companion protocol has no tabs.close tool. The
        page's window.close() only closes script-openable pages, so this
        usually raises; the MCP server surfaces the reason."""
        self.tab(tab_id)
        try:
            self.peer.close_tab(tab_id)
        except PeerError as error:
            raise RuntimeError(
                f"closing tab {tab_id} is not supported by the companion protocol "
                f"(no tabs.close tool; window.close() needs a script-opened page): {error}"
            ) from error
        with self._lock:
            self.tabs.pop(tab_id, None)
        return True

    # -- navigation ----------------------------------------------------------

    def navigate(self, tab_id, target):
        if target in ("back", "forward", "reload"):
            history = {"back": "history.back()", "forward": "history.forward()",
                       "reload": "location.reload()"}[target]
            self._execute(tab_id, f"async () => {{ {history}; return true }}")
            return {"url": self.page_url(tab_id), "title": self._tab_title(tab_id)}
        has_scheme = "://" in target or target.startswith(("about:", "data:"))
        is_local = target.startswith(("localhost", "127.0.0.1", "[::1]"))
        scheme = target if has_scheme else ("http://" if is_local else "https://") + target
        self._execute(tab_id, f"async () => {{ location.href = {json.dumps(scheme)}; return true }}")
        self._wait_settle(tab_id)
        return {"url": self.page_url(tab_id), "title": self._tab_title(tab_id)}

    def page_url(self, tab_id):
        result = self.peer.request("snapshot", {"tabId": int(tab_id)}, timeout=20.0)
        return (result.get("snapshot") or {}).get("url", "")

    def _tab_title(self, tab_id):
        result = self.peer.request("snapshot", {"tabId": int(tab_id)}, timeout=20.0)
        return (result.get("snapshot") or {}).get("title", "") or ""

    def _wait_settle(self, tab_id, timeout=30.0):
        """The DOM half of the settle, the same approximation driver.py
        makes (no network-quiet half: the extension reports no load events).
        Also caps the wait for the navigation itself to commit: the
        location.href assignment only starts the load."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self._execute(
                tab_id, SETTLE_DOM_SOURCE,
                args=[SETTLE_QUIET_DOM_MS, 5000], timeout=10.0)
            if result is True:
                return True
            time.sleep(0.1)
        return False

    # -- page calls ----------------------------------------------------------

    def _execute(self, tab_id, func_source, args=None, timeout=60.0):
        """Runs a function source in the tab's persistent isolated world and
        returns its result. Raises RuntimeError when the extension reports an
        error (the exception message the page threw, usually)."""
        params = {"tabId": int(tab_id), "funcSource": func_source}
        if args is not None:
            params["args"] = args
        try:
            result = self.peer.request("scripting.execute", params, timeout=timeout)
        except PeerError as error:
            raise RuntimeError(str(error)) from error
        return result.get("result")

    def _call_javascript(self, tab, body, arguments=None, world=WORLD):
        """driver.py interface shim: mcp_server's javascript_tool and
        content-type check call this. The `world` distinction does not exist
        here (scripting.execute is always the isolated world), and
        `arguments` are inlined as JSON (a{sv} is WebKitGTK's shape)."""
        tab_id = tab["id"] if isinstance(tab, dict) else tab
        source = "async (args) => {\n" + _inline_args(body, arguments) + "\n}"
        return self._execute(tab_id, source)

    def _page_call(self, tab, expression, world=WORLD):
        """Evaluates a plain expression (driver.py's interface shim)."""
        tab_id = tab["id"] if isinstance(tab, dict) else tab
        return self._execute(tab_id, f"async () => {{ return ({expression}) }}")

    def page_method(self, tab_id, method, args):
        """Calls a method of window.__liloAgent (AgentPage.js), injecting the
        script first into a document that lacks it, as driver.py does: the
        isolated world is persistent, so the injection happens once per
        document and later calls are plain method invocations."""
        self.tab(tab_id)
        body = json.dumps({"method": method, "args": args})
        call = (
            "async (params) => {\n"
            "  if (!window.__liloAgent) { " + _eval_source(AGENT_PAGE_JS) + "\n"
            "    if (!window.__liloAgent) return '__lilo_missing' }\n"
            "  const agent = window.__liloAgent\n"
            "  const value = await agent[params.method](params.args)\n"
            "  return value === undefined ? null : value\n"
            "}"
        )
        result = self._execute(tab_id, call, args=[json.loads(body)])
        if result == "__lilo_missing":
            # A restricted page (chrome://, the Web Store) blocks execution
            # entirely; that surfaces as a PeerError above, but a page whose
            # world cannot take globals is reported here.
            raise RuntimeError(f"AgentPage.js could not be injected into tab {tab_id}")
        return result

    # -- input ---------------------------------------------------------------

    def input_action(self, tab_id, action, ref, coordinate, text, modifiers):
        """Keyboard and pointer actions, the same route driver.py takes: a
        ref goes through AgentPage.js's act; coordinates drive DOM events."""
        if ref:
            return self.page_method(tab_id, "act", {
                "ref": ref, "action": {"left_click": "click", "double_click": "double_click",
                                       "triple_click": "triple_click", "hover": "hover",
                                       "scroll_to": "scroll_to", "right_click": "right_click"}.get(action, action),
                "modifiers": modifiers or ""})
        x, y = coordinate or (0, 0)
        if action in ("type", "insert_text"):
            focused = self.page_method(tab_id, "focusedField", {})
            if not isinstance(focused, str):
                raise RuntimeError(
                    "No text field has focus: click the field first, then type; for keys meant for the page itself, use key")
            return self._type_at_caret(tab_id, text)
        if action == "key":
            return self._key(tab_id, text)
        if action == "scroll":
            return self.page_method(tab_id, "scrollBy", {"x": x, "y": y, "dx": 0, "dy": 300})
        # Pointer by coordinate: the same event sequence driver.py dispatches.
        script = (
            "async () => {\n"
            f"  const el = document.elementFromPoint({x}, {y});\n"
            "  if (!el) return 'nothing at the point';\n"
            f"  const base = {{bubbles: true, cancelable: true, composed: true, view: window, clientX: {x}, clientY: {y}, pointerType: 'mouse', isPrimary: true}};\n"
            "  el.dispatchEvent(new PointerEvent('pointerdown', {...base, button: 0, buttons: 1}));\n"
            "  el.dispatchEvent(new MouseEvent('mousedown', {...base, button: 0, buttons: 1}));\n"
            "  el.focus?.();\n"
            "  el.dispatchEvent(new PointerEvent('pointerup', {...base, button: 0}));\n"
            "  el.dispatchEvent(new MouseEvent('mouseup', {...base, button: 0}));\n"
            "  el.click();\n"
            "  return 'clicked ' + (el.tagName.toLowerCase() + (el.id ? '#' + el.id : ''))\n"
            "}"
        )
        return self._execute(tab_id, script)

    def _type_at_caret(self, tab_id, text):
        script = (
            "async (text) => {\n"
            "  const el = document.activeElement;\n"
            "  const start = el.selectionStart ?? el.value?.length ?? 0;\n"
            "  const end = el.selectionEnd ?? start;\n"
            "  const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;\n"
            "  const before = 'value' in el ? el.value.slice(0, start) : el.textContent.slice(0, start);\n"
            "  const after = 'value' in el ? el.value.slice(end) : el.textContent.slice(end);\n"
            "  const value = before + text + after;\n"
            "  if ('value' in el) Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);\n"
            "  else el.textContent = value;\n"
            "  el.dispatchEvent(new Event('input', {bubbles: true}));\n"
            "  el.dispatchEvent(new Event('change', {bubbles: true}));\n"
            "  return 'Typed ' + text.length + ' characters'\n"
            "}"
        )
        return self._execute(tab_id, script, args=[text])

    _KEY_MAP = {
        "enter": "\r", "return": "\r", "tab": "\t", "escape": "\x1b",
        "backspace": "\b", "delete": "\x7f", "arrow_up": "\x1b[A", "arrow_down": "\x1b[B",
        "arrow_left": "\x1b[D", "arrow_right": "\x1b[C",
    }

    def _key(self, tab_id, chord):
        """A key chord, driver.py's approach: synthesized KeyboardEvents at
        the active element. The isolated world is close enough — the page's
        own listeners see the events."""
        names = [part.strip().lower() for part in chord.split("+")]
        key = names[-1]
        text = self._KEY_MAP.get(key, key if len(key) == 1 else None)
        if text is None:
            raise RuntimeError(f"Unknown key: {key}")
        flags = "".join(
            f"{name}Key: {'true' if name in names else 'false'}," for name in ("ctrl", "shift", "alt", "meta")
        )
        script = (
            "async (text, flags) => {\n"
            "  const el = document.activeElement ?? document.body;\n"
            "  for (const type of ['keydown', 'keyup']) {\n"
            "    el.dispatchEvent(new KeyboardEvent(type, {bubbles: true, cancelable: true, key: text, ...flags}))\n"
            "  }\n"
            "  return 'key ' + text\n"
            "}"
        )
        return self._execute(tab_id, script, args=[text, flags])

    # -- consent -------------------------------------------------------------

    def ask_consent(self, request):
        """No consent surface exists in this driver (no chrome view, no
        native shell): the question expires immediately, exactly as
        driver.py does without a chrome URL, and the MCP server reports
        [needs_user]. Operators run unattended containers with
        LILO_AGENT_ALLOW_ALL=1 instead — the same tradeoff, documented."""
        return {"granted": None, "alwaysAllowSite": None, "expired": True}


def _eval_source(source):
    """An indirect-eval call whose string the page cannot see: the bundled
    funcSource is already the isolated world's code, this only keeps the
    injection self-contained when AgentPage.js is missing."""
    return "window.eval(" + json.dumps(source) + ")"


def _inline_args(body, arguments):
    """driver.py's bodies read their inputs as named parameters in scope;
    here they become an `args` object the wrapper supplies. The MCP server
    only calls _call_javascript with {} arguments (javascript_tool), so the
    body runs with an empty args object; a body that doesn't use it is
    unaffected. Top-level `return` statements work because the wrapper is a
    function."""
    if arguments:
        return "const args = " + json.dumps(arguments) + ";\n" + body
    return body
