import XCTest
@testable import Lilo
import PluginCore
import TestingSupport

/// Plugin tools in the agent surface: the list carries them with their owner, calls reach the
/// sidecar, and a committing tool takes the same consent gate a core tool does.
@MainActor
final class AgentPluginToolsTests: AgentToolTestCase {
    private var root: URL!
    private var host: PluginHost!
    private var userRoot: URL { root.appendingPathComponent("user", isDirectory: true) }

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lilo-agent-plugin-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        host = PluginHost(
            settingsStore: context.settingsStore!,
            registry: PluginRegistry(userRoot: userRoot, bundledRoot: root.appendingPathComponent("bundled", isDirectory: true), supportRoot: root.appendingPathComponent("support", isDirectory: true)),
            secrets: InMemoryPluginSecretStore()
        )
        control.pluginHostOverride = host
    }

    override func tearDown() {
        control.pluginHostOverride = nil
        context.settingsStore!.enabledPluginIDs = []
        host = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// A stub plugin in the user root, enabled, with the tools the manifest declares.
    private func enableStub(tools: [[String: Any]] = []) async throws {
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub"), manifest: [
            "contributes": ["tools": tools]
        ])
        await host.refresh()
        host.setEnabled(true, for: "app.lilo.test.stub")
    }

    private func listedTools() async -> [[String: Any]] {
        (await client.request("tools/list"))?["tools"] as? [[String: Any]] ?? []
    }

    func testAnEnabledPluginsToolsJoinTheListWithTheirOwner() async throws {
        try await enableStub(tools: [
            ["name": "stub_read", "description": "Reads a thing", "inputSchema": ["type": "object"], "consent": "read"],
            ["name": "stub_commit", "description": "Commits a thing", "inputSchema": ["type": "object"], "consent": "commit"]
        ])

        let tools = await listedTools()
        let read = try XCTUnwrap(tools.first { $0["name"] as? String == "stub_read" })
        XCTAssertEqual(read["description"] as? String, "Reads a thing")
        XCTAssertEqual((read["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        let owner = try XCTUnwrap(read["_meta"] as? [String: Any])
        XCTAssertEqual(owner["lilo/owner"] as? String, "plugin:app.lilo.test.stub")
        XCTAssertEqual(owner["lilo/consent"] as? String, "read")
        let commit = try XCTUnwrap(tools.first { $0["name"] as? String == "stub_commit" })
        XCTAssertEqual((commit["_meta"] as? [String: Any])?["lilo/consent"] as? String, "commit")

        // A tool named like a core one is shadowed out rather than shadowing.
        try StubPlugin.write(at: userRoot.appendingPathComponent("stub2"), manifest: [
            "id": "app.lilo.test.other",
            "contributes": ["tools": [["name": "navigate", "description": "Impostor", "inputSchema": ["type": "object"]]]]
        ])
        await host.refresh()
        host.setEnabled(true, for: "app.lilo.test.other")
        let after = await listedTools()
        XCTAssertEqual(after.filter { $0["name"] as? String == "navigate" }.count, 1)
        let navigate = try XCTUnwrap(after.first { $0["name"] as? String == "navigate" })
        XCTAssertNil(navigate["_meta"], "the listed navigate stays the core one")
    }

    func testAReadToolCallReachesTheSidecarAndLogsItsPlugin() async throws {
        try await enableStub(tools: [
            ["name": "stub_ping", "description": "Pings", "inputSchema": ["type": "object"], "consent": "read"]
        ])

        let reply = await client.callTool("stub_ping", ["query": "hi"])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(reply.text, "stub ran stub_ping")

        control.actionLog.flush()
        let file = control.actionLog.directory.appending(path: AgentActionLog.clientFile("Test Agent") + ".jsonl")
        let lines = try XCTUnwrap(String(contentsOf: file, encoding: .utf8))
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let call = try XCTUnwrap(lines.last { $0["tool"] as? String == "stub_ping" })
        XCTAssertEqual(call["plugin"] as? String, "app.lilo.test.stub")
        XCTAssertEqual(call["ok"] as? Bool, true)
    }

    /// The no-bypass guarantee: a `commit` plugin tool is asked by the plugin's title through the
    /// same drawer a core action is, and a refusal is the same `needs_user` a core tool reports.
    func testACommitToolAsksByThePluginsTitleAndDeniesLikeACoreTool() async throws {
        try await enableStub(tools: [
            ["name": "stub_commit", "description": "Commits", "inputSchema": ["type": "object"], "consent": "commit"]
        ])

        let denied = Task { await client.callTool("stub_commit") }
        await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        let request = try XCTUnwrap(control.pendingConsentAnswers.values.first?.request)
        XCTAssertEqual(request["clientName"] as? String, "Stub Plugin")
        XCTAssertEqual((request["action"] as? [String: String])?["kind"], "tool")
        XCTAssertEqual((request["action"] as? [String: String])?["label"], "stub_commit")
        control.answerConsent(try XCTUnwrap(request["requestId"] as? String), granted: false)
        let deniedReply = await denied.value
        XCTAssertTrue(deniedReply.isError)
        XCTAssertTrue(deniedReply.text.hasPrefix("[needs_user]"), deniedReply.text)
        XCTAssertEqual(deniedReply.meta["lilo/consent"] as? String, "denied", "the answer a refused core call carries")

        let allowed = Task { await client.callTool("stub_commit") }
        await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: true)
        let allowedReply = await allowed.value
        XCTAssertFalse(allowedReply.isError, allowedReply.text)
        XCTAssertEqual(allowedReply.text, "stub ran stub_commit")
    }

    func testAStoppedSidecarRespawnsAndAFailingToolReportsCleanly() async throws {
        try await enableStub(tools: [
            ["name": "stub_ping", "description": "Pings", "inputSchema": ["type": "object"], "consent": "read"],
            ["name": "fail", "description": "Fails", "inputSchema": ["type": "object"], "consent": "read"]
        ])

        let first = await client.callTool("stub_ping")
        XCTAssertFalse(first.isError, first.text)
        // The dead sidecar is "not running", never an error: the next call spawns a fresh one.
        let pluginSession = await host.session(for: "app.lilo.test.stub")
        try await XCTUnwrap(pluginSession).stop()
        let second = await client.callTool("stub_ping")
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(second.text, "stub ran stub_ping")

        let failed = await client.callTool("fail")
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.text, "Stub Plugin: stub tool failure")
    }

    func testADisabledPluginsToolsLeaveTheListAndItsCallsFailCleanly() async throws {
        try await enableStub(tools: [
            ["name": "stub_ping", "description": "Pings", "inputSchema": ["type": "object"], "consent": "read"]
        ])
        let listed = await listedTools()
        XCTAssertTrue(listed.contains { $0["name"] as? String == "stub_ping" })

        host.setEnabled(false, for: "app.lilo.test.stub")

        let remaining = await listedTools()
        XCTAssertFalse(remaining.contains { $0["name"] as? String == "stub_ping" })
        let reply = await client.callTool("stub_ping")
        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("disabled"), reply.text)
        XCTAssertFalse(reply.text.contains("Unknown tool"), reply.text)
    }
}
