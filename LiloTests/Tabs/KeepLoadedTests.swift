import XCTest
@testable import Lilo

final class KeepLoadedTests: XCTestCase {
    private func tab(_ url: String, neverSleep: Bool = false) -> Tab {
        var tab = Tab(id: UUID(), url: URL(string: url))
        tab.neverSleep = neverSleep
        return tab
    }

    private func protectedIds(_ tabs: [Tab], hosts: Set<String> = []) -> Set<UUID> {
        var coordinator = TabLifecycleCoordinator(config: .default)
        coordinator.neverSleepHosts = hosts
        return coordinator.protectedEngineIds(tabs: tabs, availableEngineIds: Set(tabs.map(\.id)))
    }

    func testAKeptLoadedTabIsProtected() {
        let kept = tab("https://example.com/a", neverSleep: true)
        let other = tab("https://example.com/b")
        XCTAssertEqual(protectedIds([kept, other]), [kept.id])
    }

    func testAnAllowlistedHostAndItsSubdomainsAreProtected() {
        let exact = tab("https://example.com/a")
        let sub = tab("https://mail.Example.com/b")
        let lookalike = tab("https://notexample.com/c")
        let unrelated = tab("https://example.org/d")
        let ids = protectedIds([exact, sub, lookalike, unrelated], hosts: ["example.com"])
        XCTAssertEqual(ids, [exact.id, sub.id])
    }

    func testKeptLoadedTabsAreSparedByEveryDiscardPass() {
        let kept = tab("https://example.com/a", neverSleep: true)
        var coordinator = TabLifecycleCoordinator(config: .default)
        coordinator.neverSleepHosts = ["example.org"]
        let listed = tab("https://example.org/b")
        let tabs = [kept, listed]
        let ids = Set(tabs.map(\.id))
        XCTAssertEqual(coordinator.idleDiscardProtectedEngineIds(tabs: tabs, availableEngineIds: ids), ids)
    }

    func testTheSettingParsesHostnamesAndWildcards() {
        let hosts = TabLifecycleCoordinator.neverSleepHosts(from: " Mail.Example.com, *.example.org  bad/host\nexample.net,")
        XCTAssertEqual(hosts, ["mail.example.com", "example.org", "example.net"])
        XCTAssertEqual(TabLifecycleCoordinator.neverSleepHosts(from: ""), [])
    }

    func testTheFlagSurvivesTheSessionAndOldBlobsDecodeAsFalse() throws {
        var stored = StoredTab(Tab(id: UUID(), url: URL(string: "https://example.com")))
        stored.neverSleep = true
        let decoded = try JSONDecoder().decode(StoredTab.self, from: JSONEncoder().encode(stored))
        XCTAssertTrue(decoded.neverSleep)
        XCTAssertTrue(Tab(decoded, spaceId: UUID(), groupId: nil).neverSleep)

        stored.neverSleep = false
        let plain = try JSONEncoder().encode(stored)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("neverSleep"))
        XCTAssertFalse(try JSONDecoder().decode(StoredTab.self, from: plain).neverSleep)
    }

    func testTheFlagIsPartOfTheTabBridgeData() {
        var tab = Tab(id: UUID())
        tab.neverSleep = true
        XCTAssertEqual(tab.bridgeData["neverSleep"] as? Bool, true)
    }
}
