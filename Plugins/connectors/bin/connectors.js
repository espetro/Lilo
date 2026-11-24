// Connectors sidecar: the agent-app catalog (../harnesses.json) behind the `detect` and
// `configure` tools, Lilo Plugin Protocol v1 over ndjson stdio. JXA so the only runtime
// is the osascript macOS ships: JSON.parse reads the catalog and the clients' files, and
// NSWorkspace answers "is this app installed" the same way the host does. The process
// stays resident between calls, blocked on stdin; the host kills it on stop or deadline.

ObjC.import("Foundation");
ObjC.import("AppKit");
ObjC.import("stdlib");
// Loading AppKit leaves osascript's normal teardown waiting on its runloop forever:
// _exit(2) skips it when the pipe closes.
ObjC.bindFunction("_exit", ["void", ["int"]]);

const fm = $.NSFileManager.defaultManager;
const ws = $.NSWorkspace.sharedWorkspace;
const stdin = $.NSFileHandle.fileHandleWithStandardInput;
const stdout = $.NSFileHandle.fileHandleWithStandardOutput;
const root = ObjC.unwrap(fm.currentDirectoryPath);

let home = ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey("HOME"))
    || ObjC.unwrap($.NSHomeDirectory());
// Contents/Resources/Plugins/connectors -> Contents/MacOS/lilo-mcp; `initialize` may
// hand the real path, which also covers a copy installed outside the bundle.
let helper = root + "/../../../MacOS/lilo-mcp";

function readText(path) {
    const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    return text === undefined || text.isNil() ? null : ObjC.unwrap(text);
}

const catalog = (() => {
    try { return JSON.parse(readText(root + "/harnesses.json") || "[]"); } catch (_) { return []; }
})();

// The first place the client's command-line tool is executable, as the host's own check:
// ~/.local/bin, the installer's other spots, then the Homebrew prefixes.
function binaryPath(name, extra) {
    const candidates = [home + "/.local/bin/" + name]
        .concat((extra || []).map(e => home + "/" + e),
                ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]);
    for (const path of candidates) {
        if (fm.isExecutableFileAtPath(path)) return path;
    }
    return null;
}

// The client's entry for lilo in its configuration file, or null: strict JSON like the
// host's own read (a JSONC file answers "not configured"), a table scan for TOML.
function liloEntry(row) {
    const text = readText(home + "/" + row.config.path);
    if (text === null) return null;
    if (row.config.kind === "toml") {
        const table = text.match(/^\[mcp_servers\.lilo\][^\[]*/m);
        if (!table) return null;
        const command = table[0].match(/command\s*=\s*"([^"]*)"/);
        return { command: command ? command[1] : null };
    }
    let parsed;
    try { parsed = JSON.parse(text); } catch (_) { return null; }
    const servers = parsed[row.config.key || "mcpServers"];
    return (servers && typeof servers === "object" ? servers.lilo : null) || null;
}

// The `command` a client has for lilo's server; null for Claude Code, whose store only
// its CLI edits.
function commandOf(row) {
    if (row.config.kind === "claudeCLI") return null;
    const entry = liloEntry(row);
    if (!entry) return null;
    const command = entry.command;
    if (typeof command === "string") return command;
    return Array.isArray(command) ? command[0] : null;
}

// What says the client is installed: its bundle id, or its binary or folders in the home.
function installed(row) {
    const detect = row.detect || {};
    if (detect.bundleID) {
        const app = ws.URLForApplicationWithBundleIdentifier(detect.bundleID);
        if (app !== undefined && !app.isNil()) return true;
    }
    if (detect.binary && binaryPath(detect.binary, detect.binaryExtra) !== null) return true;
    return (detect.folders || []).some(folder => fm.fileExistsAtPath(home + "/" + folder));
}

function status(row) {
    const command = commandOf(row);
    return {
        id: row.id,
        installed: installed(row),
        configured: liloEntry(row) !== null,
        stale: command !== null && command !== helper,
        docsURL: row.docsURL
    };
}

// The fields lilo's entry takes in a JSON client, in the order they are written.
function entryFields(entry, helperJSON) {
    switch (entry) {
        case "stdio": return ['"type": "stdio"', '"command": ' + helperJSON, '"tools": ["*"]'];
        case "local": return ['"type": "local"', '"command": [' + helperJSON + "]"];
        default: return ['"command": ' + helperJSON];
    }
}

// What the user pastes into the client's file, the same text the settings page's
// "copy" produces.
function snippet(row) {
    const helperJSON = JSON.stringify(helper);
    if (row.config.kind === "toml") return "[mcp_servers.lilo]\ncommand = " + helperJSON + "\n";
    const key = JSON.stringify(row.config.key || "mcpServers");
    const fields = entryFields(row.config.entry, helperJSON);
    return "{\n  " + key + ': {\n    "lilo": {' + fields.map(field => "\n      " + field).join(",") + "\n    }\n  }\n}";
}

function configure(args) {
    const row = catalog.find(candidate => candidate.id === args.client);
    if (!row) return { error: { code: -32602, message: "unknown client " + JSON.stringify(args.client) } };
    const remove = args.remove === true;
    const state = status(row);
    const result = {
        client: row.id,
        kind: row.config.kind,
        path: "~/" + row.config.path,
        installed: state.installed,
        configured: state.configured,
        stale: state.stale,
        docsURL: row.docsURL
    };
    if (row.config.kind === "claudeCLI") {
        result.command = remove ? "claude mcp remove --scope user lilo"
                                : "claude mcp add --scope user lilo -- " + helper;
        result.snippet = result.command;
    } else if (remove) {
        result.snippet = "";
        result.note = row.config.kind === "toml"
            ? 'Delete the [mcp_servers.lilo] table in ' + result.path
            : 'Delete the "lilo" entry under "' + (row.config.key || "mcpServers") + '" in ' + result.path;
    } else {
        result.snippet = snippet(row);
        result.added = row.added;
        // The settings page writes the file; a JSONC one it refuses still pastes by hand.
        const existing = row.config.kind === "json" ? readText(home + "/" + row.config.path) : null;
        if (existing !== null) {
            try { JSON.parse(existing); } catch (_) { result.blocked = true; }
        }
    }
    return { result };
}

const tools = [
    {
        name: "detect",
        description: "The agent apps this Mac has and whether each one's configuration already names Lilo's MCP server (installed, configured, stale).",
        inputSchema: { type: "object" },
        consent: "read"
    },
    {
        name: "configure",
        description: "The MCP server entry Lilo needs in one agent app's configuration: the file or command, and the exact snippet or command to hand the user. It only produces the payload: nothing is written.",
        inputSchema: {
            type: "object",
            properties: {
                client: { type: "string", description: "A harness id from detect, e.g. claudeCode, cursor" },
                remove: { type: "boolean", description: "Produce the removal command instead of the add payload" }
            },
            required: ["client"]
        },
        consent: "read"
    }
];

function dispatch(object) {
    const params = object.params || {};
    switch (object.method) {
        case "initialize":
            if (typeof params.helperPath === "string") helper = params.helperPath;
            if (typeof params.home === "string") home = params.home;
            return { result: { protocolVersion: 1, tools } };
        case "tools/call":
            switch (params.name) {
                case "detect":
                    return { result: { helper, harnesses: catalog.map(status) } };
                case "configure":
                    return configure(params.arguments || {});
                default:
                    return { error: { code: -32601, message: "unknown tool " + JSON.stringify(params.name) } };
            }
        default:
            return { error: { code: -32601, message: "Method not found" } };
    }
}

function write(object) {
    const line = $.NSString.alloc.initWithUTF8String(JSON.stringify(object) + "\n");
    stdout.writeData(line.dataUsingEncoding($.NSUTF8StringEncoding));
}

// ndjson in, ndjson out, until the host closes the pipe. JXA bridges NSData.length as
// a string, so the EOF check converts it.
let buffer = "";
for (;;) {
    const data = stdin.availableData;
    if (data === undefined || Number(data.length) === 0) break;
    buffer += ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
    let index;
    while ((index = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (!line.trim()) continue;
        let object;
        try { object = JSON.parse(line); } catch (_) { continue; }
        if (object.id === undefined || object.id === null) continue;
        let reply;
        try { reply = dispatch(object); }
        catch (error) { reply = { error: { code: -32603, message: String(error) } }; }
        reply.jsonrpc = "2.0";
        reply.id = object.id;
        write(reply);
    }
}
$._exit(0);
