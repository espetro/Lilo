import XCTest
@testable import Lilo

final class BetaUpdateCheckerTests: XCTestCase {
    let feed = Data("""
    [
      {"tag_name": "beta-9", "html_url": "https://github.com/example/fork/releases/tag/beta-9", "prerelease": true},
      {"tag_name": "beta-12", "html_url": "https://github.com/example/fork/releases/tag/beta-12", "prerelease": true},
      {"tag_name": "v1.2.3", "html_url": "https://github.com/example/fork/releases/tag/v1.2.3"},
      {"tag_name": "beta-10", "prerelease": true}
    ]
    """.utf8)

    func testPicksTheLargestBetaTagWhateverTheOrderAndSkipsVersions() throws {
        XCTAssertEqual(BetaUpdateChecker.newestTag(in: feed), "beta-12")
        XCTAssertNil(BetaUpdateChecker.newestTag(in: Data("[]".utf8)))
        XCTAssertNil(BetaUpdateChecker.newestTag(in: Data("not json".utf8)))
    }

    func testFindsTheReleasePageOfTheNewestTagOnly() {
        XCTAssertEqual(BetaUpdateChecker.releaseURL(in: feed, tag: "beta-12"), "https://github.com/example/fork/releases/tag/beta-12")
        XCTAssertEqual(BetaUpdateChecker.releaseURL(in: feed, tag: "beta-10"), "")
        XCTAssertEqual(BetaUpdateChecker.releaseURL(in: feed, tag: "beta-99"), "")
    }

    func testComparesBetaTagsByNumberNotStringOrder() {
        XCTAssertTrue(BetaUpdateChecker.isNewer("beta-12", than: "beta-9"))
        XCTAssertTrue(BetaUpdateChecker.isNewer("beta-100", than: "beta-99"))
        XCTAssertFalse(BetaUpdateChecker.isNewer("beta-9", than: "beta-9"))
        XCTAssertFalse(BetaUpdateChecker.isNewer("beta-9", than: "beta-10"))
        // Tags outside the beta-N scheme never count as newer.
        XCTAssertFalse(BetaUpdateChecker.isNewer("v2.0.0", than: "beta-9"))
        XCTAssertFalse(BetaUpdateChecker.isNewer("beta-x", than: "beta-9"))
    }

    @MainActor func testAnUnusableFeedURLLeavesTheCheckerUnconfigured() {
        XCTAssertFalse(BetaUpdateChecker(feedURL: nil).isConfigured)
        XCTAssertFalse(BetaUpdateChecker(feedURL: "not a url").isConfigured)
        XCTAssertTrue(BetaUpdateChecker(feedURL: "https://updates.example.com/betas.json").isConfigured)
    }

    @MainActor func testTheInstalledTagIsRememberedAcrossChecks() {
        UserDefaults.standard.removeObject(forKey: BetaUpdateChecker.installedTagKey)
        defer { UserDefaults.standard.removeObject(forKey: BetaUpdateChecker.installedTagKey) }
        let checker = BetaUpdateChecker(feedURL: "https://updates.example.com/betas.json")
        XCTAssertTrue(checker.installedTag.isEmpty)
        checker.installedTag = "beta-7"
        XCTAssertEqual(UserDefaults.standard.string(forKey: BetaUpdateChecker.installedTagKey), "beta-7")
    }
}
