#!/usr/bin/env python3
"""lilo-mcp for the Linux container: the MCP surface over the WebKitGTK driver.

Speaks the same agent protocol the macOS app serves on its Unix socket, but
over stdio (JSON-RPC 2.0, one message per line), so an MCP client launches it
directly - the container's single user is the operator, and peer credentials
carry no meaning there.

The tool surface mirrors Lilo's (``AgentTools.definitions`` shape) with the
container's documented limits: no profiles (one ephemeral WebKitGTK session),
no devtools inspector, no terminal tabs. Consent questions are rendered by the
Svelte chrome inside the container, not a native shell.

Run inside the image: python3 /app/container/linux/mcp_server.py
"""

import json
import os
import re
import signal
import sys

sys.path.insert(0, os.path.dirname(__file__))


def load_driver(on_event):
    """LILO_DRIVER picks the backend: the default WebKitGTK driver, or
    `companion` for the user's Chromium through the companion extension."""
    if os.environ.get("LILO_DRIVER") == "companion":
        from companion_driver import Driver
        return Driver(on_event=on_event)
    from driver import Driver
    return Driver(on_event=on_event, chrome_url=os.environ.get("LILO_CHROME_URL", "") or None)

PROTOCOL_VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18"]
TOOL_DEADLINE = 55.0
LILO_VERSION = "container"

sys.path.insert(0, "/app/bench/mcp")
try:
    from fixtures import PLANNED_TOOLS  # noqa: F401
except Exception:  # noqa: BLE001 - optional, the fixture harness is not always shipped
    pass


def prop(kind, description):
    return {"type": kind, "description": description}


def enum_prop(kind, values, description):
    return {"type": kind, "enum": values, "description": description}


def tool(name, description, properties, required=None):
    return {
        "name": name,
        "description": description,
        "inputSchema": {"type": "object", "properties": properties, "required": required or []},
    }


TOOLS = [
    tool("tabs_context_mcp",
         "Get context information about your tab group. Returns all tab IDs inside the group if it exists. "
         "Each new conversation should create its own new tab (using tabs_create_mcp). Use only the tabs you "
         "created or were given.",
         {"createIfEmpty": prop("boolean", "Creates a tab group with an empty tab if none exists."),
          "title": prop("string", 'What you are working on, in 2 to 4 words ("Signup flow").')}),
    tool("tabs_create_mcp", "Creates a new empty tab, in the background. Tabs you create are yours to clean "
         "up: close each one with tabs_close_mcp as soon as you no longer need it.",
         {"title": prop("string", "What you are working on, in 2 to 4 words.")}),
    tool("tabs_close_mcp", "Closes a tab of your group.", {"tabId": prop("number", "The tab to close.")},
         ["tabId"]),
    tool("navigate", 'Navigate a tab to a URL, go "back" or "forward" in its history, or "reload". Waits for '
         "the page to settle (loaded, DOM still), then gives the final URL and title. A JSON or plain text "
         "response comes back in the reply.",
         {"url": prop("string", 'The URL to load (the scheme defaults to https://), or "back", "forward" or "reload".'),
          "tabId": prop("number", "The tab to navigate.")}, ["url", "tabId"]),
    tool("read_page",
         "Get an accessibility tree of the page: each element as role, name and a ref like [ref_N] that the "
         'other tools accept. Use filter "interactive" for clickable and typable elements only.',
         {"tabId": prop("number", "The tab to read."),
          "filter": enum_prop("string", ["interactive", "all"], '"all" (default) or "interactive".'),
          "ref_id": prop("string", "Read only this element's subtree."),
          "depth": prop("number", "Maximum tree depth (default 15)."),
          "max_chars": prop("number", "Maximum characters of output (default 50000).")}, ["tabId"]),
    tool("find", "Find elements whose role, name or text contains `query`, case-insensitively. Returns up to 20 refs.",
         {"query": prop("string", "Text to look for."), "tabId": prop("number", "The tab to search.")},
         ["query", "tabId"]),
    tool("wait_for",
         "Wait until a text or an element shows, until it is gone, or until the tab is at a URL: an upload "
         "finishing, a reply appearing, a redirect after an action.",
         {"text": prop("string", "Text to wait for."),
          "selector": prop("string", "CSS selector to wait for."),
          "role": prop("string", "ARIA role to wait for."),
          "url": prop("string", 'URL the tab reaches, "*" as wildcard.'),
          "state": enum_prop("string", ["visible", "hidden", "enabled"], "visible (default) or hidden."),
          "timeout": prop("number", "Seconds to wait (default 10, max 50)."),
          "tabId": prop("number", "The tab to watch.")}, ["tabId"]),
    tool("get_page_text", "Extracts the visible text of the page, its article or main content first.",
         {"tabId": prop("number", "The tab to read."), "max_chars": prop("number", "Maximum characters (default 50000).")},
         ["tabId"]),
    tool("form_input", "Sets the value of an input, text area, select or checkbox by its ref, and reports what "
         "the element holds afterwards.",
         {"tabId": prop("number", "The tab holding the field."),
          "ref": prop("string", "The field's ref from read_page."),
          "value": prop("string", "The value to set.")}, ["tabId", "ref", "value"]),
    tool("javascript_tool", "Runs JavaScript in the page and returns the value of its last expression; "
         "top-level await works.",
         {"tabId": prop("number", "The tab to run in."), "text": prop("string", "The code to run.")},
         ["tabId", "text"]),
    tool("computer", "Clicks, types, presses keys and scrolls in a tab, takes screenshots. Click on an element's "
         "center: take a screenshot first to find it, or pass `ref` instead. Actions: left_click, right_click, "
         "double_click, triple_click, type, insert_text, key, screenshot, wait, scroll, left_click_drag, zoom, "
         "scroll_to, hover.",
         {"tabId": prop("number", "The tab to act in."),
          "action": enum_prop("string", ["left_click", "right_click", "double_click", "triple_click", "type",
                                         "insert_text", "key", "screenshot", "wait", "scroll", "left_click_drag",
                                         "zoom", "scroll_to", "hover"], "The action to take."),
          "ref": prop("string", "The element to act on, from read_page."),
          "coordinate": prop("array", "x, y in the screenshot's pixels."),
          "text": prop("string", "Text to type or the key chord to press (ctrl+c)."),
          "modifiers": prop("string", "Modifier keys (ctrl, shift, alt, cmd), + separated.")},
         ["tabId", "action"]),
    tool("resize_window", "Sets the size of a tab's viewport to test a layout at another width.",
         {"tabId": prop("number", "The tab to resize."),
          "width": prop("number", "The width in pixels."),
          "height": prop("number", "The height in pixels.")}, ["width", "height"]),
    tool("browser_config", "A read-only snapshot of the Lilo container: its version, whether actions ask "
         "first, and the resource posture of its tabs. Nothing here can be set: ask the user to change it.", {}),
    tool("connect_status", "Returns the agent's own setup check: which agent app the container takes it for, "
         "and the consent its calls run under. Nothing can be set.", {}),
    tool("browser_batch", "Runs several tool calls in order in one round trip, stopping at the first error.",
         {"actions": prop("array", "The calls to run: [{name, input}].")}, ["actions"]),
]

TOOL_NAMES = {t["name"] for t in TOOLS}


class ToolError(Exception):
    def __init__(self, message, code=None, consent=None):
        super().__init__(message)
        self.code = code
        self.consent = consent


def content_text(text):
    return {"type": "text", "text": text}


def content_image(base64_png):
    return {"type": "image", "data": base64_png, "mimeType": "image/png"}


class Session:
    def __init__(self, name):
        self.client_name = name
        self.authorized = False
        self.title = None
        self.tab_ids = []


class Server:
    """MCP over stdio: one request at a time (an agent's calls are ordered)."""

    def __init__(self, driver, chrome_url, auto_allow=False):
        self.driver = driver
        self.chrome_url = chrome_url
        self.auto_allow = auto_allow
        self.session = None
        self._out_lock = threading.Lock()

    # -- wire ----------------------------------------------------------------

    def reply(self, id, result):
        self._send({"jsonrpc": "2.0", "id": id, "result": result})

    def error(self, id, code, message, data=None):
        body = {"code": code, "message": message}
        if data:
            body["data"] = data
        self._send({"jsonrpc": "2.0", "id": id, "error": body})

    def _send(self, message):
        line = json.dumps(message, separators=(",", ":")) + "\n"
        with self._out_lock:
            sys.stdout.write(line)
            sys.stdout.flush()

    # -- handshake and consent ----------------------------------------------

    def _authorize(self):
        if self.auto_allow:
            self.session.authorized = True
            return
        request = {
            "requestId": str(uuid.uuid4()),
            "clientName": self.session.client_name,
            "executable": "",
            "profileName": "",
            "timeout": 600,
        }
        answer = self.driver.ask_consent(request)
        self.session.authorized = answer.get("granted") is True

    # -- dispatch ------------------------------------------------------------

    def handle(self, message):
        method = message.get("method")
        if method is None:
            return
        params = message.get("params") or {}
        request_id = message.get("id")
        if request_id is None:
            return
        if method == "initialize":
            name = (params.get("clientInfo") or {}).get("name") or "Agent"
            self.session = Session(name)
            self._authorize()
            requested = params.get("protocolVersion") or ""
            return self.reply(request_id, {
                "protocolVersion": requested if requested in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[-1],
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "lilo", "version": LILO_VERSION},
                "instructions": "Lilo headless (WebKitGTK container). " +
                                ("" if self.session.authorized
                                 else "The user has not allowed this agent: tool calls will fail with needs_user."),
            })
        if method == "ping":
            return self.reply(request_id, {})
        if method == "tools/list":
            return self.reply(request_id, {"tools": TOOLS})
        if method == "tools/call":
            name = params.get("name") or ""
            arguments = params.get("arguments") or {}
            if not self.session or not self.session.authorized:
                return self.reply(request_id, {
                    "content": [content_text("[needs_user] The user did not allow this agent to control Lilo: "
                                             "answer the prompt in the Lilo window, then call the tool again")],
                    "isError": True,
                    "_meta": {"lilo/errorCode": "needs_user"},
                })
            try:
                started = time.monotonic()
                content = self.call_tool(name, arguments)
                elapsed = time.monotonic() - started
                if elapsed > TOOL_DEADLINE:
                    raise ToolError("The tool call ran past its deadline", code="timeout")
            except ToolError as failure:
                body = {"content": [content_text(failure.args[0])], "isError": True}
                meta = {}
                if failure.code:
                    meta["lilo/errorCode"] = failure.code
                if failure.consent:
                    meta["lilo/consent"] = failure.consent
                if meta:
                    body["_meta"] = meta
                return self.reply(request_id, body)
            except Exception as failure:  # noqa: BLE001 - the agent reads the reason
                return self.reply(request_id, {
                    "content": [content_text(f"{type(failure).__name__}: {failure}")], "isError": True})
            return self.reply(request_id, {"content": content})
        return self.error(request_id, -32601, f"Method not found: {method}")

    # -- tools ---------------------------------------------------------------

    def call_tool(self, name, arguments):
        handler = getattr(self, f"tool_{name}", None) or TOOL_HANDLERS.get(name)
        if handler is None:
            raise ToolError(f"Unknown tool: {name}")
        return handler(arguments)

    def _tab(self, arguments, required=True):
        tab_id = arguments.get("tabId")
        if tab_id is None and required:
            raise ToolError("tabId is required")
        return int(tab_id) if tab_id is not None else None

    def tool_tabs_context_mcp(self, arguments):
        if arguments.get("title"):
            self.session.title = arguments["title"]
        if not self.session.tab_ids and arguments.get("createIfEmpty"):
            created = self.driver.run(lambda: self.driver.create_tab(self.session.title))
            self.session.tab_ids.append(created["tabId"])
        tabs = [tab for tab in self.driver.run(self.driver.tabs_snapshot)
                if not self.session.tab_ids or tab["tabId"] in self.session.tab_ids]
        return [content_text(json.dumps({
            "availableTabs": tabs,
            "tabGroupId": self.session.title or None,
        }))]

    def tool_tabs_create_mcp(self, arguments):
        title = arguments.get("title") or self.session.title
        created = self.driver.run(lambda: self.driver.create_tab(title))
        self.session.tab_ids.append(created["tabId"])
        return [content_text(f"Created new tab. Tab ID: {created['tabId']}")]

    def tool_tabs_close_mcp(self, arguments):
        tab_id = self._tab(arguments)
        self.driver.run(lambda: self.driver.close_tab(tab_id))
        if tab_id in self.session.tab_ids:
            self.session.tab_ids.remove(tab_id)
        return [content_text(f"Closed tab {tab_id}")]

    def tool_navigate(self, arguments):
        tab_id = self._tab(arguments)
        target = (arguments.get("url") or "").strip()
        if not target:
            raise ToolError("url is required")
        result = self.driver.run(lambda: self.driver.navigate(tab_id, target))
        if isinstance(result, dict) and "__liloError" in result:
            raise ToolError(result["__liloError"])
        if not isinstance(result, dict) or "url" not in result:
            raise ToolError(f"navigate returned {result!r}")
        reply = f"Navigated to {result['url']} - {result.get('title') or ''}"
        body = self.driver.run(lambda: self.driver.page_method(tab_id, "text", {"maxChars": 50000}))
        if isinstance(body, str) and re.match(r"^(application/json|text/plain)", _content_type(self.driver, tab_id)):
            reply += "\n\n" + body[:50000]
        return [content_text(reply)]

    def tool_read_page(self, arguments):
        tab_id = self._tab(arguments)
        options = {"filter": arguments.get("filter") or "all"}
        if arguments.get("ref_id"):
            options["refId"] = arguments["ref_id"]
        if arguments.get("depth") is not None:
            options["depth"] = arguments["depth"]
        if arguments.get("max_chars") is not None:
            options["maxChars"] = arguments["max_chars"]
        text = self.driver.run(lambda: self.driver.page_method(tab_id, "readPage", options))
        return [content_text(text if isinstance(text, str) else "")]

    def tool_find(self, arguments):
        tab_id = self._tab(arguments)
        query = arguments.get("query") or ""
        matches = self.driver.run(lambda: self.driver.page_method(tab_id, "find", {"query": query}))
        if not matches:
            return [content_text(f'No element matches "{query}"')]
        return [content_text("\n".join(matches))]

    def tool_wait_for(self, arguments):
        tab_id = self._tab(arguments)
        wanted = {key: arguments.get(key) for key in ("text", "selector", "role", "url") if arguments.get(key)}
        if not wanted:
            raise ToolError("one of text, selector, role or url is required")
        state = arguments.get("state") or "visible"
        seconds = min(max(float(arguments.get("timeout") or 10), 0), 50)
        if "url" in wanted:
            return [content_text(self._wait_url(tab_id, wanted["url"], seconds))]
        args = dict(wanted)
        args["state"] = state
        args["timeoutMs"] = int(seconds * 1000)
        result = self.driver.run(lambda: self.driver.page_method(tab_id, "waitFor", args))
        if isinstance(result, dict) and "__liloError" in result:
            raise ToolError(result["__liloError"])
        return [content_text(result if isinstance(result, str) else str(result))]

    def _wait_url(self, tab_id, url, seconds):
        parts = url.split("*")
        pattern = re.compile("^" + ".*".join(re.escape(part) for part in parts) + "$") if len(parts) > 1 else None
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            current = self.driver.run(lambda: self.driver.tab(tab_id).page_url())
            if (pattern and pattern.match(current)) or current == url:
                return f"The tab is at {current}"
            time.sleep(0.1)
        return f"Timed out waiting for {url}; the tab is at {current}"

    def tool_get_page_text(self, arguments):
        tab_id = self._tab(arguments)
        args = {"maxChars": arguments.get("max_chars") or 50000}
        text = self.driver.run(lambda: self.driver.page_method(tab_id, "text", args))
        return [content_text(text if isinstance(text, str) else "")]

    def tool_form_input(self, arguments):
        tab_id = self._tab(arguments)
        ref = arguments.get("ref") or ""
        if not ref:
            raise ToolError("ref is required")
        args = {"ref": ref, "value": arguments.get("value", "")}
        reply = self.driver.run(lambda: self.driver.page_method(tab_id, "setValue", args))
        return [content_text(reply if isinstance(reply, str) else "")]

    def tool_javascript_tool(self, arguments):
        tab_id = self._tab(arguments)
        code = arguments.get("text") or ""
        return [content_text(self._run_javascript(tab_id, code))]

    def _run_javascript(self, tab_id, code):
        serialize = """
            let v
            try { v = await (async () => {
            %s
            })() } catch (e) { return { __liloError: e instanceof Error ? `${e.name}: ${e.message}` : String(e) } }
            if (v === undefined) return 'undefined'
            if (v instanceof Node) return v.outerHTML?.slice(0, 5000) ?? String(v)
            if (typeof v === 'function') return v.toString()
            try { return JSON.stringify(v, null, 2) ?? String(v) } catch { return String(v) }
            """
        # REPL semantics: `return` before the last statement when it starts an expression.
        declarations = {"const", "let", "var", "if", "for", "while", "do", "switch", "try", "function",
                        "class", "return", "throw", "import", "export"}
        statement = code.strip()
        keyword = statement.split("(")[0].strip() if statement else ""
        body = statement
        if statement and not any(statement.startswith(word + " ") or statement.startswith(word + "(")
                                 or statement == word or statement.startswith("}")
                                 for word in declarations):
            body = "return " + statement
        result = self.driver.run(
            lambda: self.driver._call_javascript(self.driver.tab(tab_id), serialize % body, {}, None))
        if isinstance(result, dict):
            if "__liloError" in result:
                raise ToolError(result["__liloError"])
            return json.dumps(result)
        return result if isinstance(result, str) else str(result)

    def tool_computer(self, arguments):
        tab_id = self._tab(arguments)
        action = arguments.get("action") or ""
        if action == "screenshot":
            return self._screenshot(tab_id, arguments)
        if action == "zoom":
            raise ToolError("zoom is not supported in the container: take a full-resolution screenshot instead")
        if action == "wait":
            seconds = min(max(float(arguments.get("text") or 1), 0), 50)
            time.sleep(seconds)
            return [content_text(f"Waited {seconds} s")]
        coordinate = arguments.get("coordinate")
        if coordinate and not isinstance(coordinate, list):
            raise ToolError("coordinate is [x, y]")
        reply = self.driver.run(lambda: self.driver.input_action(
            tab_id, action, arguments.get("ref"), coordinate, arguments.get("text") or "",
            arguments.get("modifiers") or ""))
        if isinstance(reply, dict) and "__liloError" in reply:
            raise ToolError(reply["__liloError"])
        return [content_text(reply if isinstance(reply, str) else str(reply))]

    def _screenshot(self, tab_id, arguments):
        if os.environ.get("LILO_DRIVER") == "companion":
            raise ToolError("screenshots are not supported by the companion driver: "
                            "it cannot capture the user's real browser; use read_page instead")
        import base64
        response = {}

        def finished(view, result):
            try:
                surface = view.get_snapshot_finish(result)
                response["png"] = _surface_png(surface)
            except GLib_Error:
                response["error"] = "The tab could not be captured"

        def take():
            self.driver.tab(tab_id).view.get_snapshot(
                WebKit2_SnapshotRegion.VISIBLE, WebKit2_SnapshotOptions.NONE, None, finished)

        self.driver.run(take)
        if "error" in response:
            raise ToolError(response["error"])
        return [content_image(base64.b64encode(response["png"]).decode())]

    def tool_resize_window(self, arguments):
        if os.environ.get("LILO_DRIVER") == "companion":
            raise ToolError("resizing is not supported by the companion driver: "
                            "the viewport belongs to the user's browser window")
        tab_id = self._tab(arguments)
        width = int(arguments.get("width") or 0)
        height = int(arguments.get("height") or 0)
        if not 100 <= width <= 16384 or not 100 <= height <= 16384:
            raise ToolError("width and height go from 100 to 16384")

        def resize():
            self.driver.tab(tab_id).view.set_size_request(width, height)
            self.driver.window.resize(width, height)
        self.driver.run(resize)
        return [content_text(f"Resized the viewport to {width}x{height}")]

    def tool_browser_config(self, arguments):
        return [content_text(json.dumps({
            "lilo": LILO_VERSION,
            "features": {"contentBlocker": False, "defaultZoom": 1},
            "agent": {"profile": "container", "askBeforeActions": not self.auto_allow,
                      "actionLog": False, "idlePosture": "full-rate"},
        }))]

    def tool_connect_status(self, arguments):
        return [content_text(json.dumps({
            "client": self.session.client_name if self.session else "other",
            "status": "connected",
            "fix": None,
            "consent": {"askBeforeActions": not self.auto_allow, "actsOnPages": "ask"},
        }))]

    def tool_browser_batch(self, arguments):
        content = []
        for index, action in enumerate(arguments.get("actions") or []):
            name = action.get("name") or ""
            if name == "browser_batch":
                raise ToolError("browser_batch cannot be nested")
            try:
                content += self.call_tool(name, action.get("input") or {})
            except ToolError as failure:
                done = "\n".join(part["text"] for part in content if part.get("type") == "text")
                raise ToolError(f"{done}\nAction {index + 1} ({name}) failed: {failure.args[0]}",
                                code=failure.code, consent=failure.consent)
        return content

    def tool_fetch(self, arguments):
        raise ToolError("fetch is not supported in the container: use javascript_tool from a page")


TOOL_HANDLERS = {}


def _content_type(driver, tab_id):
    result = driver.run(lambda: driver._page_call(driver.tab(tab_id), "document.contentType", world=None))
    return result if isinstance(result, str) else ""


def _surface_png(surface):
    import io

    try:
        import cairo
    except ImportError as failure:
        raise ToolError("pycairo is required for screenshots") from failure
    buffer = io.BytesIO()
    surface.write_to_png(buffer)
    return buffer.getvalue()


class _GLib_Error(Exception):
    pass


WebKit2_SnapshotRegion = None
WebKit2_SnapshotOptions = None


def main():

    chrome_url = os.environ.get("LILO_CHROME_URL", "")
    auto_allow = os.environ.get("LILO_AGENT_ALLOW_ALL") == "1"
    companion = os.environ.get("LILO_DRIVER") == "companion"
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)

    if not companion:
        global WebKit2_SnapshotRegion, WebKit2_SnapshotOptions, GLib_Error
        import gi
        gi.require_version("WebKit2", "4.0")
        from gi.repository import WebKit2 as WK, GLib
        WebKit2_SnapshotRegion = WK.SnapshotRegion
        WebKit2_SnapshotOptions = WK.SnapshotOptions
        globals()["GLib_Error"] = GLib.Error

        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk

    driver = load_driver(lambda event, data: None)
    server = Server(driver, chrome_url, auto_allow=auto_allow)

    def serve_stdio():
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                server.error(None, -32700, "Parse error")
                continue
            if isinstance(message, dict):
                server.handle(message)
        # stdin closed: the client went away, exit the whole process
        os._exit(0)

    # The Gtk main loop owns the main thread (WebKitGTK aborts on cross-thread
    # GLib use); MCP runs on a worker thread. The companion driver has no
    # loop: stdio runs on the main thread directly.
    if companion:
        serve_stdio()
        return
    threading.Thread(target=serve_stdio, daemon=True).start()
    driver.start()


if __name__ == "__main__":
    main()
