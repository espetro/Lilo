import XCTest
@testable import Lilo

/// The consent decision table and question state machine, windowless: `AgentConsentCore` and
/// `AgentConsentRules` run with no Lilo window, so a future engine driver tests them the same way.
@MainActor
final class AgentConsentCoreTests: XCTestCase {
    private var core: AgentConsentCore!
    private let tabId = UUID()

    override func setUp() async throws {
        try await super.setUp()
        core = AgentConsentCore()
    }

    func testAnAnswerResolvesTheWaitingCaller() async throws {
        let presented = expectation(description: "presented")
        core.present = { _, _ in presented.fulfill() }
        let question = Task { await self.core.ask("client\nid", request: ["clientName": "Newcomer"], tabId: nil, timeout: 5) }
        await fulfillment(of: [presented], timeout: 2)
        let requestId = try XCTUnwrap(core.pendingConsentAnswers.keys.first)
        core.answer(requestId, granted: true, allowedSites: [])
        let answer = await question.value
        XCTAssertEqual(answer, .allowed)
        XCTAssertTrue(core.pendingConsentAnswers.isEmpty, "answered questions leave")
    }

    func testARefusalAndAnExpirationResolveAsDeniedAndExpired() async throws {
        let denied = Task { await self.core.ask("a\ni", request: [:], tabId: nil, timeout: 5) }
        let requestId = try await waitForKey()
        core.answer(requestId, granted: false, allowedSites: [])
        let refused = await denied.value
        XCTAssertEqual(refused, .denied)

        let expired = Task { await self.core.ask("b\ni", request: [:], tabId: nil, timeout: 0.05) }
        let answer = await expired.value
        XCTAssertEqual(answer, .expired)
    }

    func testConcurrentConnectionsOfOneClientShareTheQuestion() async throws {
        let first = Task { await self.core.ask("c\ni", request: [:], tabId: nil, timeout: 5) }
        let second = Task { await self.core.ask("c\ni", request: [:], tabId: nil, timeout: 5) }
        await pollUntil { self.core.pendingConsents["c\ni"]?.waiting == 2 }
        XCTAssertEqual(core.pendingConsentAnswers.count, 1, "one question on the surfaces for both connections")
        core.answer(try XCTUnwrap(core.pendingConsentAnswers.keys.first), granted: true, allowedSites: [])
        let one = await first.value
        let two = await second.value
        XCTAssertEqual(one, .allowed)
        XCTAssertEqual(two, .allowed)
    }

    func testAlwaysAllowSiteSavesOnlyWhenAllowedAndNew() {
        XCTAssertEqual(core.answer("none", granted: true, alwaysAllowSite: "shop.example.com", allowedSites: []), nil, "an unknown request id saves nothing")
        XCTAssertEqual(AgentConsentRules.savingAlwaysAllowSite(true, alwaysAllowSite: "shop.example.com", sites: []), ["shop.example.com"])
        XCTAssertEqual(AgentConsentRules.savingAlwaysAllowSite(true, alwaysAllowSite: "shop.example.com", sites: ["shop.example.com"]), nil, "already listed")
        XCTAssertEqual(AgentConsentRules.savingAlwaysAllowSite(false, alwaysAllowSite: "shop.example.com", sites: []), nil, "a refusal saves nothing")
        XCTAssertEqual(AgentConsentRules.savingAlwaysAllowSite(true, alwaysAllowSite: "", sites: []), nil, "an empty site saves nothing")
    }

    func testAReloadedSurfaceGetsTheQuestionsStillWaiting() async throws {
        var shown: [[String: Any]] = []
        let others = (holdsTab: { (_: UUID) in false }, show: { shown.append($0) })
        let holder = (holdsTab: { (tab: UUID) in tab == self.tabId }, show: { shown.append($0) })
        core.answer("none", granted: nil, allowedSites: []) // no crash on an unknown id
        core.resendPending(to: [others, holder])
        XCTAssertTrue(shown.isEmpty)

        let question = Task { await self.core.ask("d\ni", request: ["clientName": "Newcomer"], tabId: self.tabId, timeout: 5) }
        _ = try await waitForKey()
        shown.removeAll()
        core.resendPending(to: [others, holder])
        XCTAssertEqual(shown.count, 1, "the question reached the surface holding its tab alone")
        core.answer(try XCTUnwrap(core.pendingConsentAnswers.keys.first), granted: nil, allowedSites: [])
        let abandoned = await question.value
        XCTAssertEqual(abandoned, .expired, "the answer stayed held: the caller resolves as unanswered")
    }

    func testTheDecisionTable() {
        func asks(sensitive: Bool = false, site: String = "shop.example.com", globalAsks: Bool = true, globalSites: [String] = [], client: AgentClientPermission? = nil) -> Bool {
            AgentClientPermission.asks(sensitive: sensitive, site: site, globalAsks: globalAsks, globalSites: globalSites, client: client)
        }
        XCTAssertFalse(asks(globalAsks: false), "the global switch off never asks")
        XCTAssertFalse(asks(globalSites: ["example.com"]), "an always-allowed site and its subdomains never ask")
        XCTAssertTrue(asks(sensitive: true, client: AgentClientPermission(act: .always)), "a sensitive action asks even an always-allowed agent")
        XCTAssertTrue(asks(client: nil), "an unknown agent asks")
        XCTAssertFalse(asks(client: AgentClientPermission(act: .always)))
        XCTAssertTrue(asks(client: AgentClientPermission(act: .sites, sites: ["other.example.com"])))
        XCTAssertFalse(asks(client: AgentClientPermission(act: .sites, sites: ["example.com"])))
        XCTAssertTrue(asks(client: AgentClientPermission(act: .ask)))
    }

    func testPermissionsRoundTripAndDropDefaults() {
        XCTAssertEqual(AgentClientPermission.encode([:]), "{}")
        XCTAssertEqual(AgentClientPermission.encode(["a": AgentClientPermission()]), "{}", "defaults are dropped")
        let json = AgentClientPermission.encode(["a": AgentClientPermission(act: .sites, sites: ["example.com"])])
        XCTAssertEqual(AgentClientPermission.decode(json), ["a": AgentClientPermission(act: .sites, sites: ["example.com"])])
        XCTAssertEqual(AgentClientPermission.decode("not json").count, 0)
        XCTAssertEqual(AgentClientPermission.decode(json)["a"]?.act, .sites)
    }

    func testDisplayName() {
        XCTAssertEqual(AgentClientNaming.displayName("claude-code"), "Claude Code")
        XCTAssertEqual(AgentClientNaming.displayName("codex-mcp-client"), "Codex")
        XCTAssertEqual(AgentClientNaming.displayName("local-agent-mode-lilo"), "Claude")
        XCTAssertEqual(AgentClientNaming.displayName("Test Agent"), "Test Agent", "a name the agent styled stays")
        XCTAssertEqual(AgentClientNaming.displayName("goose-mcp-client"), "Goose")
        XCTAssertEqual(AgentClientNaming.displayName("unknown-vscode"), "Unknown VS Code")
    }

    func testConsentErrorsCarryTheAnswer() {
        XCTAssertEqual(AgentConsentRules.expiredConsentError(timeout: 45).consent, .expired)
        XCTAssertEqual(AgentConsentRules.expiredConsentError(timeout: 45).code, "needs_user")
        XCTAssertEqual(AgentConsentRules.unavailableConsentError.consent, .unavailable)
    }

    private func waitForKey(timeout: TimeInterval = 2) async throws -> String {
        await pollUntil { !self.core.pendingConsentAnswers.isEmpty }
        return try XCTUnwrap(core.pendingConsentAnswers.keys.first)
    }
}
