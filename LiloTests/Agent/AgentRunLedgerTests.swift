import XCTest
@testable import Lilo

@MainActor
final class AgentRunLedgerTests: AgentToolTestCase {
    private var logDirectory: URL { URL(fileURLWithPath: context.appSupportDirectory).appending(path: "Agents/Actions") }
    private var runFile: URL { logDirectory.appending(path: "runs.jsonl") }

    private func runEvents() throws -> [[String: Any]] {
        control.actionLog.flush()
        guard let data = try? Data(contentsOf: runFile) else { return [] }
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private func hasRunEnd(_ reason: String) -> Bool {
        ((try? runEvents()) ?? []).contains { $0["event"] as? String == "end" && $0["reason"] as? String == reason }
    }

    func testAnAuthorizedSessionWritesItsStartAndEnd() async throws {
        let session = try XCTUnwrap(control.sessions.first)
        _ = await client.callTool("tabs_context_mcp")

        client.close()
        let ended = await pollUntil(timeout: 5) { self.hasRunEnd("disconnected") }
        XCTAssertTrue(ended, "the closed session's run end was not logged")

        let events = try runEvents()
        XCTAssertEqual(events.map { $0["event"] as? String }, ["start", "end"])
        let start = try XCTUnwrap(events.first)
        XCTAssertEqual(start["run"] as? String, session.id.uuidString)
        XCTAssertEqual(start["client"] as? String, "Test Agent")
        XCTAssertEqual((start["clientKey"] as? String)?.count, 16, "a short pseudonymous hash, never the identity itself")
        XCTAssertNotEqual(start["clientKey"] as? String, session.identity)
        XCTAssertNotNil(start["connected"] as? String)
        let end = try XCTUnwrap(events.last)
        XCTAssertEqual(end["run"] as? String, session.id.uuidString)
        XCTAssertEqual(end["tools"] as? Int, 1)
        XCTAssertEqual(end["errors"] as? Int, 0)
        XCTAssertEqual(end["tabs"] as? Int, 0)
        XCTAssertNotNil(end["ts"] as? String)
    }

    func testFailedCallsCountAsErrors() async throws {
        _ = await client.callTool("no_such_tool")

        client.close()
        let ended = await pollUntil(timeout: 5) { self.hasRunEnd("disconnected") }
        XCTAssertTrue(ended)

        let end = try XCTUnwrap(try runEvents().last)
        XCTAssertEqual(end["tools"] as? Int, 1)
        XCTAssertEqual(end["errors"] as? Int, 1)
    }

    func testRevokingTheClientEndsTheRunAsRevoked() async throws {
        control.revoke("Test Agent")

        let ended = await pollUntil(timeout: 5) { self.hasRunEnd("revoked") }
        XCTAssertTrue(ended, "the revoked session's run end was not logged")
    }

    func testAClientThatNeverInitializesLeavesNoRun() async throws {
        let stranger = try AgentTestClient(path: socketURL)
        stranger.close()
        let gone = await pollUntil(timeout: 5) { self.control.sessions.count == 1 }
        XCTAssertTrue(gone)

        let events = try runEvents()
        XCTAssertEqual(events.filter { $0["event"] as? String == "start" }.count, 1, "only the setUp client's")
        XCTAssertTrue(events.allSatisfy { $0["event"] as? String != "end" }, "the stranger's connection wrote nothing")
    }

    func testAnAdoptedSessionEndsItsRunAsAdopted() async throws {
        _ = try await newAgentTab()
        // The heir connects while the first agent still runs: same name and process, as a reconnect is.
        let heir = try AgentTestClient(path: socketURL)
        defer { heir.close() }
        _ = await heir.initialize(name: "Test Agent")

        client.close()
        let adopted = await pollUntil(timeout: 5) { self.hasRunEnd("adopted") }
        XCTAssertTrue(adopted, "the dropped session's run did not end as adopted")

        let runs = AgentRunLedger.recent(in: logDirectory)
        XCTAssertEqual(runs.filter { $0.ended == nil }.count, 1, "the heir's run stays open")
        XCTAssertEqual(runs.first { $0.reason == "adopted" }?.client, "Test Agent")
    }

    func testALiveRunHasNoEnd() throws {
        let runs = AgentRunLedger.recent(in: logDirectory)
        let run = try XCTUnwrap(runs.first, "the setUp client's run is still open")
        XCTAssertEqual(run.id, try XCTUnwrap(control.sessions.first).id.uuidString)
        XCTAssertNil(run.ended)
        XCTAssertNil(run.reason)
        XCTAssertEqual(run.client, "Test Agent")
        XCTAssertFalse(run.clientKey.isEmpty)
    }

    func testRecentMergesTheStartAndEnd() async throws {
        let session = try XCTUnwrap(control.sessions.first)
        _ = await client.callTool("tabs_context_mcp")
        client.close()
        let ended = await pollUntil(timeout: 5) { self.hasRunEnd("disconnected") }
        XCTAssertTrue(ended)

        let runs = AgentRunLedger.recent(in: logDirectory)
        XCTAssertEqual(runs.count, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.id, session.id.uuidString)
        XCTAssertEqual(run.client, "Test Agent")
        XCTAssertNotNil(run.started)
        XCTAssertNotNil(run.ended)
        XCTAssertEqual(run.reason, "disconnected")
        XCTAssertEqual(run.tools, 1)
        XCTAssertEqual(run.errors, 0)
    }

    func testTheActionLogSettingCoversTheRunLedger() async throws {
        context.settingsStore!.set(AgentActionLog.settingKey, value: "false")
        let other = try AgentTestClient(path: socketURL)
        defer { other.close() }
        _ = await other.initialize(name: "Codex")

        control.actionLog.flush()
        let starts = try runEvents().filter { $0["event"] as? String == "start" }
        XCTAssertEqual(starts.count, 1, "only the setUp client's, logged before the setting went off")
    }

    func testRunRecordsCarryNoPageData() async throws {
        let tab = try await agentTab(showing: "<input id=a type=password>")
        _ = await client.callTool("form_input", ["tabId": tab, "ref": "ref_missing", "value": "hunter2-secret"])

        client.close()
        let ended = await pollUntil(timeout: 5) { self.hasRunEnd("disconnected") }
        XCTAssertTrue(ended)

        control.actionLog.flush()
        let raw = (try? String(contentsOf: runFile, encoding: .utf8)) ?? ""
        for leak in ["hunter2", "http", "example.com"] {
            XCTAssertFalse(raw.contains(leak), "\(leak) leaked into the run ledger: \(raw)")
        }
    }

    /// The reader on its own: pairs merge across the rotation boundary, an end without a start still
    /// lists, and the newest start wins the order.
    func testRecentReadsPairsAndSorts() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = [
            #"{"client":"one","clientKey":"k1","connected":"2025-12-31T23:59:00Z","event":"start","run":"a","ts":"2026-01-01T00:00:00Z"}"#,
            #"{"errors":1,"event":"end","folders":["f1"],"isolated":true,"profile":"p1","reason":"disconnected","run":"a","space":"s1","tabs":3,"tools":4,"ts":"2026-01-01T00:10:00Z"}"#,
            #"{"client":"two","clientKey":"k2","conversation":"c1","event":"start","run":"b","ts":"2026-01-02T00:00:00Z"}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: directory.appending(path: "runs.jsonl"), atomically: true, encoding: .utf8)

        let runs = AgentRunLedger.recent(in: directory)
        XCTAssertEqual(runs.map(\.id), ["b", "a"], "most recently started first")
        let a = try XCTUnwrap(runs.first { $0.id == "a" })
        XCTAssertEqual(a.client, "one")
        XCTAssertEqual(a.ended, "2026-01-01T00:10:00Z")
        XCTAssertEqual(a.reason, "disconnected")
        XCTAssertEqual(a.tools, 4)
        XCTAssertEqual(a.errors, 1)
        XCTAssertEqual(a.tabs, 3)
        XCTAssertEqual(a.folders, ["f1"])
        XCTAssertEqual(a.space, "s1")
        XCTAssertEqual(a.profile, "p1")
        XCTAssertTrue(a.isolated)
        let b = try XCTUnwrap(runs.first { $0.id == "b" })
        XCTAssertNil(b.ended)
        XCTAssertEqual(b.conversation, "c1")
    }
}
