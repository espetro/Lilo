import XCTest
@testable import Lilo

/// The page snapshot, delta and settling logic over a scripted `AgentPageHost`, windowless: no web view,
/// no keyboard, no `LILO_LOCAL_UI_TESTS`.
@MainActor
final class AgentPageCoreTests: XCTestCase {
    /// A page host driven by recorded replies: what `AgentPageCore` asks, the test answers.
    private final class FakeHost: AgentPageHost {
        var currentURL: URL?
        var isLoading = false
        var lastNetworkActivity: ContinuousClock.Instant?
        var replies: [String: (AgentPageFrame?) throws -> Any?] = [:]
        var asked: [(method: String, frame: AgentPageFrame?)] = []
        var subframePrefixes: [String] = []
        var quietResult: Bool?
        var quietDelay: Duration = .zero

        func page(_ method: String, _ arguments: [String: Any], in frame: AgentPageFrame?) async throws -> Any? {
            asked.append((method, frame))
            return try replies[method]?(frame)
        }

        func subframes() async -> [(prefix: String, frame: AgentPageFrame)] {
            subframePrefixes.map { (prefix: $0, frame: Frame()) }
        }

        func domQuiet(quietMs: Int, maxMs: Int) async -> Bool? {
            if quietDelay > .zero { try? await Task.sleep(for: quietDelay) }
            return quietResult
        }

        final class Frame: AgentPageFrame {}
    }

    override func setUp() async throws {
        try await super.setUp()
        AgentSettle.quiet = (dom: .milliseconds(5), network: .milliseconds(5))
    }

    override func tearDown() async throws {
        AgentSettle.quiet = (dom: .milliseconds(200), network: .milliseconds(500))
        try await super.tearDown()
    }

    func testSnapshotCoversTheMainFrameAndEachSubframe() async throws {
        let host = FakeHost()
        host.subframePrefixes = ["f1_", "f2_"]
        await AgentPageCore.snapshot(host)
        XCTAssertEqual(host.asked.map(\.method), ["snapshot", "snapshot", "snapshot"], "main frame first, then each subframe")
        XCTAssertFalse(host.asked[0].frame === host.asked[1].frame, "each subframe got its own frame")
    }

    func testDeltaJoinsChangedFramesAndSkipsEmptyOnes() async throws {
        let host = FakeHost()
        host.subframePrefixes = ["f1_"]
        host.replies["delta"] = { frame in frame == nil ? "- a" : "+ b" }
        let delta = await AgentPageCore.delta(host)
        XCTAssertEqual(delta, "- a\n\n+ b")

        let silent = FakeHost()
        silent.replies["delta"] = { _ in "" }
        let silentDelta = await AgentPageCore.delta(silent)
        XCTAssertNil(silentDelta, "nothing changed anywhere")
    }

    func testDeltaReportNamesANavigationThenTheDelta() async throws {
        let host = FakeHost()
        host.currentURL = URL(string: "https://shop.example.com/cart")
        host.replies["delta"] = { _ in "~ moved" }
        let report = await AgentPageCore.deltaReport(host, urlBefore: URL(string: "https://shop.example.com/"))
        XCTAssertEqual(report, "The page is now at https://shop.example.com/cart\n~ moved")

        host.currentURL = URL(string: "https://shop.example.com/cart")
        let noNavigation = await AgentPageCore.deltaReport(host, urlBefore: URL(string: "https://shop.example.com/cart"))
        XCTAssertEqual(noNavigation, "~ moved")

        let quiet = FakeHost()
        quiet.currentURL = URL(string: "https://shop.example.com/cart")
        let unchanged = await AgentPageCore.deltaReport(quiet, urlBefore: URL(string: "https://shop.example.com/cart"))
        XCTAssertEqual(unchanged, "No page changes")
    }

    func testLoadWaitSettlesWhenThePageIsQuiet() async {
        let host = FakeHost()
        host.isLoading = false
        host.currentURL = URL(string: "https://shop.example.com/")
        host.quietResult = true
        host.lastNetworkActivity = .now
        let settled = await AgentPageCore.waitForLoad(host)
        XCTAssertTrue(settled, "a quiet page settles")
        XCTAssertEqual(host.asked.count, 0, "settling runs the probe, not the page tools")
    }

    func testLoadWaitFollowsAScriptRedirect() async {
        let host = FakeHost()
        host.currentURL = URL(string: "https://shop.example.com/a")
        host.quietResult = true
        let wait = Task { await AgentPageCore.waitForLoad(host) }
        try? await Task.sleep(for: .milliseconds(50))
        host.isLoading = true
        try? await Task.sleep(for: .milliseconds(80))
        host.isLoading = false
        host.currentURL = URL(string: "https://shop.example.com/b")
        let settled = await wait.value
        XCTAssertTrue(settled, "a redirect restarts the settle, then the wait still succeeds")
    }

    func testLoadWaitEndsWhenTheProbeCannotRun() async {
        let host = FakeHost()
        host.currentURL = URL(string: "https://shop.example.com/")
        host.quietResult = nil
        let settled = await AgentPageCore.waitForLoad(host)
        XCTAssertTrue(settled, "a gone document ends the wait, trusting the load is over")
    }

    func testLoadWaitGivesUpPastThirtySeconds() async {
        let host = FakeHost()
        host.isLoading = true
        let wait = Task { await AgentPageCore.waitForLoad(host) }
        try? await Task.sleep(for: .milliseconds(120))
        host.isLoading = false
        host.quietResult = false
        let settled = await wait.value
        XCTAssertEqual(settled, false, "a page that never quiets reports itself as it is")
    }

    private func pollUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
