import XCTest
@testable import Lilo

/// The tab-patch bookkeeping, pure bridge payloads: runs wherever `swift test` does.
final class BrowserCoreTests: XCTestCase {
    private let spaceId = UUID()

    private func payload(id: String, url: String = "https://example.com/", title: String? = "Example") -> [String: Any] {
        var payload: [String: Any] = [TabBridgeField.id.rawValue: id, TabBridgeField.url.rawValue: url]
        if let title { payload[TabBridgeField.title.rawValue] = title }
        return payload
    }

    private func tab(_ event: BrowserChangePresenter.Event?) -> [String: Any] {
        let operation = try! XCTUnwrap(event?.data["operations"] as? [[String: Any]]).first!
        return try! XCTUnwrap(operation["tab"] as? [String: Any])
    }

    func testFirstPayloadShipsComplete() throws {
        var core = BrowserCore()
        let event = try XCTUnwrap(core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId))
        XCTAssertEqual(event.name, "browserStatePatch")
        XCTAssertEqual(try XCTUnwrap(tab(event)[TabBridgeField.title.rawValue] as? String), "Example")
    }

    func testUnchangedPayloadShipsNothing() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        XCTAssertNil(core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId))
    }

    func testChangedPayloadShipsIdAndChangedFieldsOnly() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        var changed = payload(id: "t1", title: "Renamed")
        changed[TabBridgeField.isLoading.rawValue] = true
        let shipped = try XCTUnwrap(tab(core.tabUpdateEvent(changed, spaceId: spaceId)))
        // id + title + isLoading; the title change pulls the url along for the blank-title fallback.
        XCTAssertEqual(shipped.count, 4)
        XCTAssertEqual(try XCTUnwrap(shipped[TabBridgeField.title.rawValue] as? String), "Renamed")
        XCTAssertEqual(try XCTUnwrap(shipped[TabBridgeField.isLoading.rawValue] as? Bool), true)
    }

    func testTitleChangeCarriesUrlForBlankTitleFallback() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        let changed = payload(id: "t1", title: "Renamed")
        let shipped = try XCTUnwrap(tab(core.tabUpdateEvent(changed, spaceId: spaceId)))
        // The chrome falls back to the url for a blank title, so a title patch ships both.
        XCTAssertNotNil(shipped[TabBridgeField.title.rawValue])
        XCTAssertNotNil(shipped[TabBridgeField.url.rawValue])
    }

    func testValueOfDifferentTypeCountsAsChange() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        var changed = payload(id: "t1")
        changed[TabBridgeField.title.rawValue] = NSNull()
        XCTAssertNotNil(core.tabUpdateEvent(changed, spaceId: spaceId))
    }

    func testPayloadWithoutIdIsIgnored() {
        var core = BrowserCore()
        XCTAssertNil(core.tabUpdateEvent([TabBridgeField.title.rawValue: "No id"], spaceId: spaceId))
        XCTAssertTrue(core.sentTabPatches.isEmpty)
    }

    func testTabsAreTrackedIndependently() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        _ = core.tabUpdateEvent(payload(id: "t2"), spaceId: spaceId)
        // id + title, with the url pulled along by the title change.
        let shipped = try XCTUnwrap(tab(core.tabUpdateEvent(payload(id: "t2", title: "Other"), spaceId: spaceId)))
        XCTAssertEqual(shipped.count, 3)
    }

    func testClearAllSentTabPatchesResendsComplete() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        core.clearAllSentTabPatches()
        let shipped = try XCTUnwrap(tab(core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)))
        XCTAssertEqual(shipped.count, 3)
    }

    func testSidebarPatchReseedsUpsertedAndRemovedTabs() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        _ = core.tabUpdateEvent(payload(id: "t2"), spaceId: spaceId)
        core.clearSentTabPatches(in: [
            ["upsertTabs": [payload(id: "t1")], "removedTabIds": ["t2"]]
        ])
        XCTAssertEqual(try XCTUnwrap(tab(core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId))).count, 3)
        XCTAssertEqual(try XCTUnwrap(tab(core.tabUpdateEvent(payload(id: "t2"), spaceId: spaceId))).count, 3)
    }

    func testClearKeepsTabsOutsideThePatch() throws {
        var core = BrowserCore()
        _ = core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId)
        core.clearSentTabPatches(in: [["removedTabIds": ["other"]]])
        XCTAssertNil(core.tabUpdateEvent(payload(id: "t1"), spaceId: spaceId))
    }
}

/// The command classification the window applies around the store's mutation.
final class BrowserCoreEffectsTests: XCTestCase {
    private let spaceId = UUID()
    private let folderId = UUID()
    private let tabId = UUID()

    private func facts(
        kind: Tab.Kind = .web, isPinned: Bool = false, isClosed: Bool = false, isBookmarked: Bool = false
    ) -> BrowserCore.TabFacts {
        BrowserCore.TabFacts(kind: kind, isPinned: isPinned, isClosed: isClosed, isBookmarked: isBookmarked)
    }

    private func effects(
        _ command: BrowserCommand,
        facts: BrowserCore.TabFacts? = nil,
        folderTabs: Set<UUID> = []
    ) -> BrowserCore.BrowserCommandEffects {
        BrowserCore.effects(
            of: command,
            tabFacts: { _ in facts },
            folderTabIds: { _, _ in folderTabs }
        )
    }

    func testClosingATerminalTakesItsScreenAlong() {
        let effects = effects(.closeTab(spaceId: spaceId, tabId: tabId), facts: facts(kind: .terminal))
        XCTAssertEqual(effects.closingTerminalTabId, tabId)
    }

    func testClosingAWebTabLeavesNoTerminal() {
        let effects = effects(.closeTab(spaceId: spaceId, tabId: tabId), facts: facts(kind: .web))
        XCTAssertNil(effects.closingTerminalTabId)
    }

    func testClosingAnUnknownTabLeavesNoTerminal() {
        let effects = effects(.closeTab(spaceId: spaceId, tabId: tabId))
        XCTAssertNil(effects.closingTerminalTabId)
    }

    func testUnpinningAClosedPinnedTabTakesItOutOfTheSidebar() {
        let effects = effects(
            .setPinned(spaceId: spaceId, tabId: tabId, isPinned: false),
            facts: facts(isPinned: true, isClosed: true)
        )
        XCTAssertEqual(effects.removedTabId, tabId)
        XCTAssertEqual(effects.previousPinnedState, true)
    }

    func testUnpinningAnOpenTabKeepsItInTheSidebar() {
        let effects = effects(
            .setPinned(spaceId: spaceId, tabId: tabId, isPinned: false),
            facts: facts(isPinned: true, isClosed: false)
        )
        XCTAssertNil(effects.removedTabId)
    }

    func testUnbookmarkingAClosedBookmarkTakesItOutOfTheSidebar() {
        let effects = effects(
            .setBookmarked(spaceId: spaceId, tabId: tabId, isBookmarked: false),
            facts: facts(isClosed: true, isBookmarked: true)
        )
        XCTAssertEqual(effects.removedTabId, tabId)
    }

    func testPinningATabRecordsThePreviousState() {
        let effects = effects(
            .setPinned(spaceId: spaceId, tabId: tabId, isPinned: true),
            facts: facts(isPinned: false)
        )
        XCTAssertEqual(effects.previousPinnedState, false)
        XCTAssertNil(effects.removedTabId)
    }

    func testDeletingAFolderWithItsTabsNamesTheSpaceAndTabs() {
        let ids: Set<UUID> = [UUID(), UUID()]
        let effects = effects(
            .deleteFolderWithTabs(spaceId: spaceId, folderId: folderId),
            folderTabs: ids
        )
        XCTAssertEqual(effects.deletedFolderSpaceId, spaceId)
        XCTAssertEqual(effects.deletedFolderTabIds, ids)
    }

    func testOtherCommandsHaveNoEffects() {
        let effects = effects(.activateTab(spaceId: spaceId, tabId: tabId), facts: facts(kind: .terminal))
        XCTAssertNil(effects.closingTerminalTabId)
        XCTAssertNil(effects.removedTabId)
        XCTAssertNil(effects.previousPinnedState)
        XCTAssertNil(effects.deletedFolderSpaceId)
        XCTAssertTrue(effects.deletedFolderTabIds.isEmpty)
    }
}
