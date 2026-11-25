import XCTest
@testable import PluginCore

/// The bundled connectors plugin, run for real over stdio: `detect` reads a fake home and
/// `configure` produces the same payloads the app's install path writes.
final class ConnectorsPluginTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var session: PluginSession!
    private let helper = "/TEST/lilo-mcp"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-connectors-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // #filePath: <repo>/Packages/LiloPluginKit/Tests/PluginCoreTests/<this file>
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("Plugins/connectors"), to: folder)
        let manifest = try PluginManifest.load(at: folder)
        XCTAssertEqual(manifest.capabilities, [])
        XCTAssertEqual(manifest.contributes.tools.map(\.name), ["detect", "configure"])
        XCTAssertEqual(manifest.contributes.tools.map(\.consentTier), [.read, .read])
        let helper = helper
        let homePath = home.path
        session = PluginSession(manifest: manifest, pluginRoot: folder, initializeParams: {
            ["helperPath": .string(helper), "home": .string(homePath)]
        })
        try await session.start()
    }

    override func tearDown() async throws {
        await session.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await session.request("tools/call", params: ["name": .string(name), "arguments": .object(arguments)])
    }

    private func resultObject(_ result: JSONValue, _ context: String) throws -> [String: JSONValue] {
        try XCTUnwrap(result.objectValue, context)
    }

    private func harness(_ result: JSONValue, id: String) async throws -> [String: JSONValue] {
        let object = try resultObject(result, "no result object for \(id)")
        let harnesses = try XCTUnwrap(object["harnesses"]?.arrayValue, "no harnesses for \(id)")
        return try XCTUnwrap(harnesses.lazy.compactMap(\.objectValue).first { $0["id"] == .string(id) }, "no \(id) row")
    }

    private func write(_ text: String, to path: String) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testDetectListsEveryHarnessInCatalogOrder() async throws {
        let object = try resultObject(await call("detect"), "no result object")
        XCTAssertEqual(object["helper"], .string(helper))
        let harnesses = try XCTUnwrap(object["harnesses"]?.arrayValue, "no harnesses")
        XCTAssertEqual(harnesses.compactMap { $0.objectValue?["id"]?.stringValue },
                       ["claudeCode", "claudeDesktop", "codex", "cursor", "zed", "vscode", "opencode", "gemini"])
        // An empty home means nothing is configured, whatever the machine has installed.
        XCTAssertTrue(harnesses.allSatisfy { $0.objectValue?["configured"] == .bool(false) })
    }

    func testDetectReadsTheHomeItsInitializeParamsNamed() async throws {
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try write(#"{"mcpServers": {"lilo": {"command": "\#(helper)"}}}"#, to: ".gemini/settings.json")
        // A binary-only install: opencode's installer path under the fake home.
        let binary = home.appending(path: ".opencode/bin/opencode")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let result = try await call("detect")
        let claude = try await harness(result, id: "claudeCode")
        XCTAssertEqual(claude["installed"], .bool(true))
        XCTAssertEqual(claude["configured"], .bool(false))
        let opencode = try await harness(result, id: "opencode")
        XCTAssertEqual(opencode["installed"], .bool(true))
        let gemini = try await harness(result, id: "gemini")
        // Its settings file's own folder is what the installed heuristic looks for.
        XCTAssertEqual(gemini["installed"], .bool(true))
        XCTAssertEqual(gemini["configured"], .bool(true))
        XCTAssertEqual(gemini["stale"], .bool(false))
    }

    func testDetectMarksAConfigNamingAnotherLiloAsStale() async throws {
        try write(#"{"mcpServers": {"lilo": {"command": "/other/lilo-mcp"}}}"#, to: ".gemini/settings.json")
        let gemini = try await harness(try await call("detect"), id: "gemini")
        XCTAssertEqual(gemini["configured"], .bool(true))
        XCTAssertEqual(gemini["stale"], .bool(true))
    }

    func testDetectReadsCodexsTOMLTable() async throws {
        try write("[mcp_servers.other]\ncommand = \"/bin/other\"\n\n[mcp_servers.lilo]\ncommand = \"\(helper)\"\n", to: ".codex/config.toml")
        let codex = try await harness(try await call("detect"), id: "codex")
        XCTAssertEqual(codex["configured"], .bool(true))
        XCTAssertEqual(codex["stale"], .bool(false))
    }

    func testConfigureProducesTheSameSnippetTheAppWrites() async throws {
        let payload = try resultObject(await call("configure", arguments: ["client": .string("cursor")]), "no payload")
        XCTAssertEqual(payload["client"], .string("cursor"))
        XCTAssertEqual(payload["path"], .string("~/.cursor/mcp.json"))
        XCTAssertEqual(payload["kind"], .string("json"))
        XCTAssertEqual(payload["added"], .string("Added Lilo to Cursor"))
        let snippet = try XCTUnwrap(payload["snippet"]?.stringValue, "no snippet")
        XCTAssertTrue(snippet.contains("\"mcpServers\""), snippet)
        XCTAssertTrue(snippet.contains("\"lilo\""), snippet)
        XCTAssertTrue(snippet.contains(helper), snippet)
    }

    func testConfigureProducesEachEntryShapeAndTheClaudeCommand() async throws {
        for (client, fragment) in [
            ("zed", "\"context_servers\""), ("vscode", "\"type\": \"stdio\""), ("opencode", "\"type\": \"local\"")
        ] {
            let payload = try resultObject(
                await call("configure", arguments: ["client": .string(client)]), "no payload for \(client)")
            let snippet = try XCTUnwrap(payload["snippet"]?.stringValue, "no snippet for \(client)")
            XCTAssertTrue(snippet.contains(fragment), "\(client): \(snippet)")
        }
        let payload = try resultObject(await call("configure", arguments: ["client": .string("claudeCode")]), "no payload")
        XCTAssertEqual(payload["command"], .string("claude mcp add --scope user lilo -- \(helper)"))
        XCTAssertEqual(payload["kind"], .string("claudeCLI"))
    }

    func testConfigureRemoveAndAnUnknownClient() async throws {
        let payload = try resultObject(
            await call("configure", arguments: ["client": .string("claudeCode"), "remove": .bool(true)]), "no payload")
        XCTAssertEqual(payload["command"], .string("claude mcp remove --scope user lilo"))
        do {
            _ = try await call("configure", arguments: ["client": .string("unknown")])
            XCTFail("an unknown client must fail")
        } catch let error as PluginSessionError {
            guard case .rpc(_, let message) = error else {
                return XCTFail("expected an rpc error, got \(error)")
            }
            XCTAssertTrue(message.contains("unknown client"), message)
        }
    }
}
