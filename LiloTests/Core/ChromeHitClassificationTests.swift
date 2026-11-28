import XCTest
@testable import Lilo

/// Pure hit-classification rules, no windows: runs wherever `swift test` does.
final class ChromeHitClassificationTests: XCTestCase {
    // MARK: - Pointer target

    func testZoneHitIsChrome() {
        XCTAssertEqual(ChromeHitClassification.target(isOverChromeZone: true, hasContent: true), .chrome)
    }

    func testMissWithContentIsContent() {
        XCTAssertEqual(ChromeHitClassification.target(isOverChromeZone: false, hasContent: true), .content)
    }

    func testMissWithoutContentIsNone() {
        XCTAssertEqual(ChromeHitClassification.target(isOverChromeZone: false, hasContent: false), .none)
    }

    func testZoneHitWinsWithoutContent() {
        XCTAssertEqual(ChromeHitClassification.target(isOverChromeZone: true, hasContent: false), .chrome)
    }

    // MARK: - Drag target

    func testDragOverZoneIsChrome() {
        XCTAssertEqual(
            ChromeHitClassification.dragTarget(
                isOverChromeZone: true, routesToChrome: false, hasContent: true, contentIsModal: false
            ),
            .chrome
        )
    }

    // The window hands a drag over the page to the chrome (a link aimed at a split side).
    func testDragRoutedToChromeIsChrome() {
        XCTAssertEqual(
            ChromeHitClassification.dragTarget(
                isOverChromeZone: false, routesToChrome: true, hasContent: true, contentIsModal: false
            ),
            .chrome
        )
    }

    func testDragOverContentIsContent() {
        XCTAssertEqual(
            ChromeHitClassification.dragTarget(
                isOverChromeZone: false, routesToChrome: false, hasContent: true, contentIsModal: false
            ),
            .content
        )
    }

    // A page under its tab-modal dialog takes no drop.
    func testDragOverModalPageIsNone() {
        XCTAssertEqual(
            ChromeHitClassification.dragTarget(
                isOverChromeZone: false, routesToChrome: false, hasContent: true, contentIsModal: true
            ),
            .none
        )
    }

    func testDragWithoutContentIsNone() {
        XCTAssertEqual(
            ChromeHitClassification.dragTarget(
                isOverChromeZone: false, routesToChrome: false, hasContent: false, contentIsModal: false
            ),
            .none
        )
    }

    // The chrome owns the drag even over a modal page: the modal only blocks the content.
    func testDragRoutedToChromeBeatsModalPage() {
        XCTAssertEqual(
            ChromeHitClassification.dragTarget(
                isOverChromeZone: false, routesToChrome: true, hasContent: true, contentIsModal: true
            ),
            .chrome
        )
    }
}
