import XCTest
@testable import Lilo

@MainActor
final class TabSleepStateTests: XCTestCase {
    func testDiscardMarksTheTabSleepingAndKeepsUserSettings() {
        let overlay = RuntimeOverlayStore()
        let id = UUID()
        var live = Tab(id: id)
        live.isMuted = true
        live.isLoading = true
        overlay.setRuntimeState(from: live)

        overlay.discardRuntimeState(for: id)

        let applied = overlay.applied(to: Tab(id: id))
        XCTAssertTrue(applied.isSleeping)
        XCTAssertTrue(applied.isMuted)
        XCTAssertFalse(applied.isLoading)
    }

    func testDiscardOfATabWithoutRuntimeStateStillMarksItSleeping() {
        let overlay = RuntimeOverlayStore()
        let id = UUID()
        overlay.discardRuntimeState(for: id)
        XCTAssertTrue(overlay.applied(to: Tab(id: id)).isSleeping)
    }

    func testWakeClearsTheSleepingFlag() {
        let overlay = RuntimeOverlayStore()
        let id = UUID()
        overlay.discardRuntimeState(for: id)
        var awake = overlay.applied(to: Tab(id: id))
        awake.isSleeping = false
        overlay.setRuntimeState(from: awake)
        XCTAssertFalse(overlay.applied(to: Tab(id: id)).isSleeping)
    }

    func testSleepingIsPartOfTheRuntimePatch() {
        var tab = Tab(id: UUID())
        tab.isSleeping = true
        XCTAssertEqual(tab.runtimePatchData["isSleeping"] as? Bool, true)
    }
}
