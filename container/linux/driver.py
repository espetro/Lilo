#!/usr/bin/env python3
"""The WebKitGTK driver of Lilo's containerized MCP surface: tabs, pages, input.

One process owns every WebKitGTK web view and the Gtk main loop; the MCP server
(``mcp_server.py``) calls into it over the driver's request/response line
protocol on a socketpair (see ``wire.py``). This mirrors the seam PR #186
created: the page logic itself lives in ``Lilo/Agent/AgentPage.js`` (verbatim,
this file injects it into the page's "lilo-agent" isolated world), and only
the driver-side plumbing is new.

What it implements, per tool need:
  - tab bookkeeping (create/close/list) with integer tab ids like Lilo's
  - navigation with goBack/goForward/reload and the settle wait
  - ``AgentPage.js`` method calls (snapshot, delta, readPage, act, ...) in the
    "lilo-agent" isolated content world, cross-origin subframes excluded
    (WebKitGTK evaluates against the main frame only, a documented gap)
  - synthetic input: clicks, typing and keys via synthesized DOM events, the
    same approach ``AgentPage.js``'s ``act`` takes in a frame
  - consent questions forwarded to the Svelte chrome (``agentControlRequested``
    bridge event) rendered in a second WebKitGTK view, and the user's answer
    posted back through the ``agentControlResponse`` bridge command

Headless: WebKitGTK under Xvfb inside the container, no native shell.
"""

import json
import queue
import re
import threading
import time

import gi

gi.require_version("WebKit2", "4.0")
gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, WebKit2  # noqa: E402

AGENT_PAGE_JS = open("/app/Lilo/Agent/AgentPage.js", encoding="utf-8").read()
WORLD = "lilo-agent"
# The same word lists AgentPage.js matches a label against when the native
# side asks whether a click is consequential; kept here for the chrome view.
SETTLE_QUIET_DOM_MS = 200
SETTLE_QUIET_NET_MS = 500
SETTLE_DOM_SCRIPT = """
return await new Promise(resolve => {
  let quiet
  const done = settled => { observer.disconnect(); clearTimeout(quiet); clearTimeout(cap); resolve(settled) }
  const wait = () => { clearTimeout(quiet); quiet = setTimeout(() => done(document.readyState === 'complete'), quietMs) }
  const observer = new MutationObserver(wait)
  observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true })
  const cap = setTimeout(() => done(false), maxMs)
  wait()
})
"""


class Tab:
    """One web view: the driver's equivalent of a WKWebViewTab, agent-owned."""

    def __init__(self, tab_id, title):
        self.id = tab_id
        self.title = title
        self.view = WebKit2.WebView()
        # AgentPage.js rides as a user script in the "lilo-agent" world, the
        # WebKitGTK equivalent of macOS's isolated-world injection: page
        # scripts can't see it, and unlike call_async_javascript_function's
        # ephemeral world contexts, its globals (the ref maps) persist for
        # the life of the document.
        manager = self.view.get_user_content_manager()
        manager.add_script(WebKit2.UserScript.new_for_world(
            AGENT_PAGE_JS,
            WebKit2.UserContentInjectedFrames.TOP_FRAME,
            WebKit2.UserScriptInjectionTime.END, WORLD, None, None))
        self.view.show()
        self.pending_consent = None  # requestId of the consent this tab's page asked
        self.load_started_at = None

    def page_url(self):
        uri = self.view.get_uri()
        return uri or ""

    def is_loading(self):
        return self.view.is_loading()


class Driver:
    """Owns the Gtk loop, the tabs and the consent chrome view."""

    def __init__(self, on_event, chrome_url=None):
        # Gtk.init first: a WebKit2.WebView needs a display connection at
        # construction, not at show time.
        Gtk.init([])
        self.next_tab_id = 1
        self.tabs = {}
        self.on_event = on_event  # (event, data) -> None, thread-safe
        self.chrome_ready = threading.Event()
        self._calls = queue.Queue()
        self._loop_thread = None  # set by start(): the thread that runs Gtk.main

        # The consent surface: the Lilo Svelte chrome served by the UI dev
        # server, loaded in its own WebKitGTK view. Same bridge event and
        # command names the macOS shell speaks (agentControlRequested /
        # agentControlResponse), so the chrome code runs unmodified. Only
        # created when a chrome URL is given: without it there is no consent
        # surface and no second view to keep alive.
        self.chrome = ChromeView(self._on_chrome_command) if chrome_url else None
        self.chrome_url = chrome_url
        self.window = Gtk.Window()
        self.window.set_default_size(1280, 800)
        self.window.connect("destroy", Gtk.main_quit)

    # -- bridge plumbing (called from the MCP server thread) ----------------

    def wait_chrome_ready(self, timeout=30.0):
        return self.chrome_ready.wait(timeout)

    def run(self, fn, timeout=60.0):
        """Runs fn on the Gtk main loop thread and returns its result.

        Cross-thread GLib calls abort WebKitGTK in the container, so calls
        cross threads through a plain queue the main loop drains. A call that
        is already on the loop thread (a nested run from a tool call) runs
        inline instead of deadlocking on the queue.
        """
        if threading.current_thread() is self._loop_thread:
            try:
                return fn()
            except Exception as error:  # noqa: BLE001 - forwarded verbatim
                return {"__liloError": f"{type(error).__name__}: {error}"}
        done = threading.Event()
        slot = {}

        def runner():
            try:
                slot["value"] = fn()
            except Exception as error:  # noqa: BLE001 - forwarded verbatim
                slot["value"] = {"__liloError": f"{type(error).__name__}: {error}"}
            done.set()

        self._calls.put(runner)
        if not done.wait(timeout):
            return {"__liloError": "timed out on the Gtk main loop"}
        return slot.get("value")

    # -- tab operations ------------------------------------------------------

    def tabs_snapshot(self):
        return [
            {"tabId": tab.id, "title": tab.title, "url": tab.page_url()}
            for tab in self.tabs.values()
        ]

    def create_tab(self, title):
        tab = Tab(self.next_tab_id, title or "Agent")
        self.next_tab_id += 1
        self.tabs[tab.id] = tab
        self.window.add(tab.view)
        return {"tabId": tab.id}

    def tab(self, tab_id):
        if tab_id not in self.tabs:
            raise KeyError(f"No tab {tab_id}")
        return self.tabs[tab_id]

    def close_tab(self, tab_id):
        tab = self.tab(tab_id)
        self.window.remove(tab.view)
        tab.view.destroy()
        del self.tabs[tab_id]
        return True

    # -- navigation ----------------------------------------------------------

    def navigate(self, tab_id, target):
        tab = self.tab(tab_id)
        if target == "back":
            tab.view.go_back()
        elif target == "forward":
            tab.view.go_forward()
        elif target == "reload":
            tab.view.reload()
        else:
            has_scheme = "://" in target or target.startswith(("about:", "data:"))
            is_local = target.startswith(("localhost", "127.0.0.1", "[::1]"))
            scheme = target if has_scheme else ("http://" if is_local else "https://") + target
            tab.view.load_uri(scheme)
        self._wait_settle(tab)
        return {"url": tab.page_url(), "title": self._tab_title(tab)}

    def _tab_title(self, tab):
        return self._page_call(tab, "document.title", world=None) or ""

    def _wait_settle(self, tab, timeout=30.0):
        """The settle of AgentPageCore.waitForLoad, DOM half: WebKitGTK gives
        no network activity signal, so the network quiet is skipped.

        The load is asynchronous: is_loading flips to True a tick after
        load_uri, so first wait for the load to start (or the page to land),
        then for the DOM to go quiet.
        """
        started = time.monotonic()
        while time.monotonic() - started < 0.5:
            if tab.is_loading() or tab.page_url() != "about:blank":
                break
            time.sleep(0.02)
        deadline = time.monotonic() + timeout
        arguments = {
            "quietMs": GLib.Variant("i", SETTLE_QUIET_DOM_MS),
            "maxMs": GLib.Variant("i", 5000),
        }
        while time.monotonic() < deadline:
            if not tab.is_loading():
                result = self._call_javascript(
                    tab, SETTLE_DOM_SCRIPT, arguments, world=WORLD)
                if isinstance(result, dict):
                    return False
                if result is True:
                    return True
            time.sleep(0.05)
        return False

    # -- page calls ----------------------------------------------------------

    def _call_javascript(self, tab, body, arguments=None, world=WORLD):
        """Evaluates an async function body in a content world, on the main
        loop, and decodes the result (string, number, bool or null).

        WebKitGTK's call_async_javascript_function: the `arguments` Variant is
        a{sv} whose keys become named parameters of the body's function scope,
        and the result is a JavaScriptCore.Value."""
        if arguments is None or not arguments:
            arguments = None
        response = {}

        def finished(view, result):
            try:
                value = view.call_async_javascript_function_finish(result)
                response["value"] = self._js_value(value)
            except GLib.Error as error:
                response["value"] = {"__liloError": error.message}
            done.set()

        done = threading.Event()

        def call():
            tab.view.call_async_javascript_function(
                body, -1, arguments, world, None, None, finished)

        self.run(call, timeout=60.0)
        if threading.current_thread() is self._loop_thread:
            # Nested call on the loop thread: the callback needs the loop to
            # keep dispatching, so poll the event while pumping iterations
            # (the modal-dialog pattern) instead of blocking.
            context = GLib.main_context_default()
            deadline = time.monotonic() + 60.0
            while not done.is_set() and time.monotonic() < deadline:
                if not context.iteration(False):
                    time.sleep(0.01)
        elif not done.wait(timeout=60.0):
            return {"__liloError": "the page never answered the script call"}
        return response.get("value")

    @staticmethod
    def _js_value(value):
        if value is None:
            return None
        try:
            from gi.repository import JavaScriptCore  # noqa: F401 - probe only
            if value.is_string():
                return value.to_string()
            if value.is_number():
                return value.to_double()
            if value.is_boolean():
                return value.to_boolean()
            if value.is_null() or value.is_undefined():
                return None
            # Arrays and objects: through their JSON form, as WKWebView's
            # callAsyncJavaScript does.
            return json.loads(value.to_json(0))
        except RuntimeError:  # noqa: BLE001 - not installed: fall back to text
            return value.to_string()

    def _page_call(self, tab, expression, world=WORLD):
        """Evaluates a plain expression, page world by default."""
        return self._call_javascript(tab, f"return {expression}", {}, world)

    def page_method(self, tab_id, method, args):
        """Calls a method of window.__liloAgent (AgentPage.js), injecting the
        script first into a document that lacks it, as AgentTools.page does."""
        tab = self.tab(tab_id)
        body = json.dumps({"method": method, "args": args})
        call = (
            "const parameters = " + body + ";\n"
            "if (!window.__liloAgent) return '__lilo_missing'\n"
            "return await window.__liloAgent[parameters.method](parameters.args)"
        )
        result = self._call_javascript(tab, call, {}, WORLD)
        if result == "__lilo_missing":
            full = AGENT_PAGE_JS + "\n" + call
            result = self._call_javascript(tab, full, {}, WORLD)
        if isinstance(result, dict) and "__liloError" in result:
            raise RuntimeError(result["__liloError"])
        return result

    # -- input ---------------------------------------------------------------

    def input_action(self, tab_id, action, ref, coordinate, text, modifiers):
        """Keyboard and pointer actions. A ref goes through AgentPage.js's
        act (DOM events); a coordinate drives the page's own element."""
        tab = self.tab(tab_id)
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
            self._set_value_at_caret(tab, text)
            return f"Typed {len(text)} characters"
        if action == "key":
            return self._key(tab, text)
        if action == "scroll":
            return self.page_method(tab_id, "scrollBy", {"x": x, "y": y, "dx": 0, "dy": 300})
        # Pointer by coordinate: dispatch the DOM event sequence at the point.
        script = (
            f"const el = document.elementFromPoint({x}, {y});"
            "if (!el) return 'nothing at the point';"
            "const box = el.getBoundingClientRect();"
            "const base = {bubbles: true, cancelable: true, composed: true, view: window,"
            f" clientX: {x}, clientY: {y}, pointerType: 'mouse', isPrimary: true}};"
            "el.dispatchEvent(new PointerEvent('pointerdown', {...base, button: 0, buttons: 1}));"
            "el.dispatchEvent(new MouseEvent('mousedown', {...base, button: 0, buttons: 1}));"
            "el.focus?.();"
            "el.dispatchEvent(new PointerEvent('pointerup', {...base, button: 0}));"
            "el.dispatchEvent(new MouseEvent('mouseup', {...base, button: 0}));"
            "el.click();"
            "return 'clicked ' + (el.tagName.toLowerCase() + (el.id ? '#' + el.id : ''))"
        )
        return self._call_javascript(tab, f"return (function(){{ {script} }})()", {}, WORLD)

    def _set_value_at_caret(self, tab, text):
        script = (
            "const el = document.activeElement;"
            "const start = el.selectionStart ?? el.value?.length ?? 0;"
            "const end = el.selectionEnd ?? start;"
            "const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;"
            "const before = 'value' in el ? el.value.slice(0, start) : el.textContent.slice(0, start);"
            "const after = 'value' in el ? el.value.slice(end) : el.textContent.slice(end);"
            f"const value = before + {json.dumps(text)} + after;"
            "if ('value' in el) Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);"
            "else el.textContent = value;"
            "el.dispatchEvent(new Event('input', {bubbles: true}));"
            "el.dispatchEvent(new Event('change', {bubbles: true}));"
            "return true"
        )
        self._call_javascript(tab, f"return (function(){{ {script} }})()", {}, WORLD)

    _KEY_MAP = {
        "enter": "\r", "return": "\r", "tab": "\t", "escape": "\x1b",
        "backspace": "\b", "delete": "\x7f", "arrow_up": "\x1b[A", "arrow_down": "\x1b[B",
        "arrow_left": "\x1b[D", "arrow_right": "\x1b[C",
    }

    def _key(self, tab, chord):
        """A key chord: synthesizes the events a page's own key listener sees.
        Modifiers alter the event flags; the key's own meaning stays."""
        names = [part.strip().lower() for part in chord.split("+")]
        key = names[-1]
        text = self._KEY_MAP.get(key, key if len(key) == 1 else None)
        if text is None:
            raise RuntimeError(f"Unknown key: {key}")
        flags = "".join(
            f"{name}Key: {'true' if name in names else 'false'}," for name in ("ctrl", "shift", "alt", "meta")
        )
        event = ("new KeyboardEvent(type, {bubbles: true, cancelable: true, key: "
                 + json.dumps(text) + ", " + flags[:-1] + "})")
        script = (
            "const el = document.activeElement ?? document.body;"
            "for (const type of ['keydown', 'keyup']) {"
            f"  el.dispatchEvent({event});"
            "}"
            "return 'key ' + " + json.dumps(chord)
        )
        return self._call_javascript(tab, f"return (function(){{ {script} }})()", {}, None)

    # -- consent -------------------------------------------------------------

    def ask_consent(self, request):
        """Sends a consent question to the chrome view, returns when answered
        (or a timeout). Called from the MCP server thread."""
        response = {}

        def done(granted, always_allow_site):
            response["granted"] = granted
            response["alwaysAllowSite"] = always_allow_site
            event.set()

        if self.chrome is None:
            # No chrome URL: no consent surface, so the question expires
            # immediately and the MCP server reports [needs_user].
            return {"granted": None, "alwaysAllowSite": None, "expired": True}
        event = threading.Event()

        def ask():
            self.chrome.ask(request, done)

        self.run(ask, timeout=request.get("timeout", 120))
        timeout = request.get("timeout", 120)
        if not event.wait(timeout):
            return {"granted": None, "alwaysAllowSite": None, "expired": True}
        response.setdefault("granted", None)
        return response

    def start(self, on_idle=None):
        """Runs the Gtk main loop on the calling (main) thread until
        process exit, draining cross-thread calls. The MCP server runs its
        stdio loop on a worker thread; when a chrome URL is set, the chrome
        view is loaded first and its handshake waited for.
        """
        self._loop_thread = threading.current_thread()
        if self.chrome_url:
            self.chrome.load(self.chrome_url)
            self.chrome.send_initial_state()
            if not self.wait_chrome_ready(30):
                raise RuntimeError("the chrome view did not connect")

        def drain():
            try:
                while True:
                    call = self._calls.get_nowait()
                    call()
            except queue.Empty:
                return True  # keep polling

        GLib.timeout_add(10, drain)
        if on_idle:
            GLib.idle_add(on_idle)
        Gtk.main()

    def _on_chrome_command(self, action, payload):
        """Bridge commands from the chrome view: the consent answer and the
        connection handshake the chrome asks for at startup."""
        if action == "ready":
            self.chrome_ready.set()
            return True
        if action == "initialStateApplied":
            return True
        return False


class ChromeView:
    """The Svelte chrome in a WebKitGTK view: renders consent questions.

    Speaks the same wire protocol as the macOS shell's WKWebView bridge:
    posts ``{action, payload}`` commands through a script message handler,
    receives ``{event, data}`` envelopes through ``window.__lilo.receive``.
    """

    INITIAL_STATE = {
        "tabs": [], "treeItems": [], "activeTabId": "", "sidebarWidth": 240,
        "sidebarVisible": False, "toolbarVisible": False, "trafficLightsVisible": False,
        "isFullscreen": True, "spaces": [], "profiles": [],
    }

    def __init__(self, on_command):
        self.view = WebKit2.WebView()
        manager = self.view.get_user_content_manager()
        manager.register_script_message_handler("lilo")
        manager.connect("script-message-received", self._message, on_command)
        self.on_command = on_command
        self.on_answer = None
        self.current_request = None
        self.settings = self.view.get_settings()
        self.settings.set_enable_developer_extras(False)

    def load(self, url):
        self.view.load_uri(url)
        self.view.show()

    def _message(self, manager, message, on_command):
        try:
            value = message.get_value()
            posted = json.loads(value.to_string())
            action = posted.get("action")
            payload = posted.get("payload", {})
        except Exception:  # noqa: BLE001 - a malformed post is dropped
            return
        if action == "agentControlResponse" and self.on_answer:
            self.on_answer(payload.get("granted"), payload.get("alwaysAllowSite"))
            self.on_answer = None
            self.current_request = None
            return
        on_command(action, payload)

    def ask(self, request, done):
        """Sends the question (agentControlRequested), the chrome's drawer
        shows it; the answer comes back as agentControlResponse."""
        self.on_answer = done
        self.current_request = request.get("requestId")
        self.send_event("agentControlRequested", {
            "requestId": request.get("requestId"),
            "clientName": request.get("clientName", "Agent"),
            "executable": request.get("executable", ""),
            "profileName": request.get("profileName", ""),
            "action": request.get("action"),
        })

    def send_event(self, event, data):
        envelope = json.dumps({"event": event, "data": data})
        script = f"window.__lilo && window.__lilo.receive({envelope})"
        self.view.run_javascript(script, None, None, None)

    def send_initial_state(self):
        self.send_event("initialState", self.INITIAL_STATE)
        self.send_event("settingsLoaded", {
            "settings": {"agentAskBeforeActions": "true", "agentControlEnabled": "true"}
        })
