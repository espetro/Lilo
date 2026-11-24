import Foundation

/// One agent app Lilo can register its MCP server with: where it lives, where its configuration is and which
/// first-party page the shape of that configuration comes from. The rows live in the bundled connectors
/// plugin (`Plugins/connectors/harnesses.json`): the app's install path and the plugin's sidecar read the
/// same catalog, so the knowledge exists once and a plugin the user disables changes nothing here.
struct HarnessDefinition: Equatable, Sendable {
    /// How the server is added to the client, with the file `connectedClients` reads back, relative to the home.
    enum Config: Equatable, Sendable {
        /// `claude mcp add` owns the file; Lilo only reads it.
        case claudeCLI(store: String)
        /// `<key>.lilo`, merged into the file's other keys. Only a file that parses as strict JSON is written:
        /// the apps whose settings take comments (Zed, OpenCode) get copy instructions instead of a rewrite.
        case json(path: String, key: String = "mcpServers", entry: Entry = .command)
        /// A `[mcp_servers.lilo]` table, replaced in place.
        case toml(path: String)

        var path: String {
            switch self {
            case .claudeCLI(let path), .json(let path, _, _), .toml(let path): path
            }
        }
    }

    /// What the client wants under Lilo's name: each app words the same stdio command its own way.
    enum Entry: Equatable, Sendable {
        /// `{"command": ...}`
        case command
        /// `{"type": "stdio", "command": ..., "tools": ["*"]}`
        case stdio
        /// `{"type": "local", "command": [...]}`
        case local

        /// The entry's fields in the order they are written, values as JSON; `helper` is already a JSON string.
        func fields(_ helper: String) -> KeyValuePairs<String, String> {
            switch self {
            case .command: ["command": helper]
            case .stdio: ["type": "\"stdio\"", "command": helper, "tools": "[\"*\"]"]
            case .local: ["type": "\"local\"", "command": "[\(helper)]"]
            }
        }
    }

    /// What says the client is installed. At least one must be set: a row nobody can detect is never shown.
    struct Detect: Equatable, Sendable {
        var bundleID: String?
        /// The command-line tool, looked up in `~/.local/bin`, `binaryExtra` and the Homebrew prefixes.
        var binary: String?
        /// Where the tool's installer also puts it, relative to the home.
        var binaryExtra: [String] = []
        /// Folders the tool leaves in the home (relative), for an install elsewhere.
        var folders: [String] = []
    }

    let id: String
    let config: Config
    let detect: Detect
    /// The agent's handshake names (lowercased), exact or by prefix.
    let handshakes: [String]
    let handshakePrefixes: [String]
    /// The first-party page the configuration shape comes from, and the day it was last checked against it.
    let docsURL: String
    let verified: String
    /// What the settings page says after Connect: the English key `NativeStrings` translates.
    let added: @Sendable () -> String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var rawValue: String { id }

    init?(rawValue: String) {
        guard let found = Self.all.first(where: { $0.id == rawValue }) else { return nil }
        self = found
    }

    /// The client behind the name an agent gives when it connects ("claude-ai" is Claude Desktop).
    init?(clientName: String) {
        let lowered = clientName.lowercased()
        guard let found = Self.all.first(where: { $0.handshakes.contains(lowered) || $0.handshakePrefixes.contains(where: lowered.hasPrefix) }) else { return nil }
        self = found
    }

    private init(id: String, config: Config, detect: Detect, handshakes: [String], handshakePrefixes: [String] = [],
                 docsURL: String, verified: String, added: @escaping @Sendable () -> String) {
        self.id = id
        self.config = config
        self.detect = detect
        self.handshakes = handshakes
        self.handshakePrefixes = handshakePrefixes
        self.docsURL = docsURL
        self.verified = verified
        self.added = added
    }

    /// The catalog's JSON shape; `key`/`entry`/`binaryExtra`/`folders`/`handshakePrefixes` default
    /// like their Swift counterparts and `note` is the row's own documentation.
    private struct Row: Decodable {
        let id: String
        let config: Config
        let detect: Detect
        let handshakes: [String]
        let handshakePrefixes: [String]?
        let docsURL: String
        let verified: String
        let added: String

        struct Config: Decodable {
            let kind: String
            let path: String
            let key: String?
            let entry: String?
        }

        struct Detect: Decodable {
            let bundleID: String?
            let binary: String?
            let binaryExtra: [String]?
            let folders: [String]?
        }
    }

    private init(row: Row) {
        let config: Config
        switch row.config.kind {
        case "claudeCLI": config = .claudeCLI(store: row.config.path)
        case "toml": config = .toml(path: row.config.path)
        default:
            let entry: Entry = switch row.config.entry {
            case "stdio": .stdio
            case "local": .local
            default: .command
            }
            config = .json(path: row.config.path, key: row.config.key ?? "mcpServers", entry: entry)
        }
        let added = row.added
        self.init(
            id: row.id, config: config,
            detect: Detect(
                bundleID: row.detect.bundleID, binary: row.detect.binary,
                binaryExtra: row.detect.binaryExtra ?? [], folders: row.detect.folders ?? []
            ),
            handshakes: row.handshakes, handshakePrefixes: row.handshakePrefixes ?? [],
            docsURL: row.docsURL, verified: row.verified, added: { added.localized }
        )
    }

    static let claudeCode = named("claudeCode")
    static let claudeDesktop = named("claudeDesktop")
    static let codex = named("codex")
    static let cursor = named("cursor")
    static let zed = named("zed")
    static let vscode = named("vscode")
    static let opencode = named("opencode")
    static let gemini = named("gemini")

    /// The catalog row, or an inert one when a broken bundle cannot name it: the empty `detect`
    /// keeps it off every list and `init(rawValue:)` never finds it.
    private static func named(_ id: String) -> HarnessDefinition {
        all.first { $0.id == id } ?? HarnessDefinition(
            id: id, config: .json(path: ""), detect: Detect(), handshakes: [], docsURL: "", verified: "", added: { "" }
        )
    }

    /// In the order the settings page lists them: the connectors plugin's catalog, the single file
    /// its sidecar also reads.
    static let all: [HarnessDefinition] = {
        guard let url = catalogURL,
              let rows = try? JSONDecoder().decode([Row].self, from: Data(contentsOf: url)) else { return [] }
        return rows.map(HarnessDefinition.init(row:))
    }()

    /// `Plugins/connectors/harnesses.json` inside the bundle, or the checkout's copy: `swift test`
    /// has no bundle, so the fallback resolves the file from this file's place in the checkout.
    private static let catalogURL: URL? = {
        if let bundled = Bundle.main.url(forResource: "harnesses", withExtension: "json", subdirectory: "Plugins/connectors") {
            return bundled
        }
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Plugins/connectors/harnesses.json")
        return FileManager.default.fileExists(atPath: checkout.path) ? checkout : nil
    }()
}
