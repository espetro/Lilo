import XCTest
@testable import Lilo

/// Pure geometry, no windows: runs wherever `swift test` does.
final class SplitGeometryTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private var twoPanesVertical: SplitLayout {
        .split(vertical: true, ratio: 0.5, first: .pane(tabId: a), second: .pane(tabId: b))
    }

    private var twoPanesHorizontal: SplitLayout {
        .split(vertical: false, ratio: 0.5, first: .pane(tabId: a), second: .pane(tabId: b))
    }

    // MARK: - frames

    func testLeafPaneGetsWholeRect() {
        let (panes, cuts) = SplitGeometry.frames(.pane(tabId: a), in: CGRect(x: 0, y: 0, width: 100, height: 50), flipped: true)
        XCTAssertEqual(panes, [a: CGRect(x: 0, y: 0, width: 100, height: 50)])
        XCTAssertTrue(cuts.isEmpty)
    }

    func testVerticalSplitFlippedFirstOnTop() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 208)
        let (panes, cuts) = SplitGeometry.frames(twoPanesVertical, in: rect, flipped: true)
        // 208 - 8 gap = 200, half is 100.
        XCTAssertEqual(panes[a], CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(panes[b], CGRect(x: 0, y: 108, width: 100, height: 100))
        let cut = try! XCTUnwrap(cuts[[]])
        XCTAssertTrue(cut.vertical)
        XCTAssertEqual(cut.bounds, rect)
        XCTAssertEqual(cut.divider, CGRect(x: 0, y: 100, width: 100, height: 8))
    }

    func testVerticalSplitUnflippedFirstStillOnTop() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 208)
        let (panes, _) = SplitGeometry.frames(twoPanesVertical, in: rect, flipped: false)
        // Unflipped counts y from the bottom: the first pane sits at the top.
        XCTAssertEqual(panes[a], CGRect(x: 0, y: 108, width: 100, height: 100))
        XCTAssertEqual(panes[b], CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testHorizontalSplit() {
        let rect = CGRect(x: 0, y: 0, width: 208, height: 100)
        let (panes, cuts) = SplitGeometry.frames(twoPanesHorizontal, in: rect, flipped: true)
        XCTAssertEqual(panes[a], CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(panes[b], CGRect(x: 108, y: 0, width: 100, height: 100))
        XCTAssertEqual(try! XCTUnwrap(cuts[[]]).divider, CGRect(x: 100, y: 0, width: 8, height: 100))
    }

    func testUnevenRatioRoundsFirstLength() {
        let layout = SplitLayout.split(vertical: false, ratio: 1.0 / 3.0, first: .pane(tabId: a), second: .pane(tabId: b))
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let (panes, cuts) = SplitGeometry.frames(layout, in: rect, flipped: true)
        // (100 - 8) / 3 rounds to 31; the second pane absorbs the remainder.
        XCTAssertEqual(panes[a]?.width, 31)
        XCTAssertEqual(panes[a]?.minX, 0)
        XCTAssertEqual(panes[b], CGRect(x: 39, y: 0, width: 61, height: 100))
        XCTAssertEqual(try! XCTUnwrap(cuts[[]]).divider.minX, 31)
    }

    func testNestedSplitCutsKeyedByPath() {
        let layout = SplitLayout.split(
            vertical: false, ratio: 0.5, first: twoPanesVertical, second: .pane(tabId: c)
        )
        let rect = CGRect(x: 0, y: 0, width: 208, height: 208)
        let (panes, cuts) = SplitGeometry.frames(layout, in: rect, flipped: true)
        XCTAssertEqual(Set(panes.keys), [a, b, c])
        XCTAssertEqual(cuts.count, 2)
        XCTAssertNotNil(cuts[[]])
        XCTAssertNotNil(cuts[[false]])
        XCTAssertNil(cuts[[true]])
        XCTAssertNil(cuts[[true, false]])
        // The root cut splits left/right; the nested one splits the left half top/bottom.
        XCTAssertEqual(try! XCTUnwrap(cuts[[false]]).vertical, true)
        XCTAssertEqual(try! XCTUnwrap(cuts[[]]).vertical, false)
        XCTAssertEqual(panes[c]?.width, 100)
        XCTAssertEqual(panes[c]?.minX, 108)
    }

    // MARK: - cut(at:in:)

    func testCutAtResolvesSubtreeAndRejectsLeaf() {
        XCTAssertNotNil(SplitGeometry.cut(at: [], in: twoPanesVertical))
        XCTAssertNil(SplitGeometry.cut(at: [false], in: twoPanesVertical))
        XCTAssertNil(SplitGeometry.cut(at: [true], in: twoPanesVertical))
    }

    // MARK: - minimumLength

    func testMinimumLengthOfLeafIsPaneMinimum() {
        XCTAssertEqual(SplitGeometry.minimumLength(of: .pane(tabId: a), vertical: true), SplitGeometry.minimumPaneLength)
    }

    func testMinimumLengthStacksDividersAlongCutAxis() {
        // Along the cut's own axis the two panes and their divider stack: 200 + 8 + 200.
        let expected = SplitGeometry.minimumPaneLength * 2 + SplitGeometry.dividerWidth
        XCTAssertEqual(SplitGeometry.minimumLength(of: twoPanesHorizontal, vertical: false), expected)
        // Across the cut's axis the parts are independent: the taller one wins.
        XCTAssertEqual(SplitGeometry.minimumLength(of: twoPanesHorizontal, vertical: true), SplitGeometry.minimumPaneLength)
    }

    func testMinimumLengthOfNestedSplitAddsNestedDividers() {
        let layout = SplitLayout.split(
            vertical: true, ratio: 0.5, first: twoPanesVertical, second: .pane(tabId: c)
        )
        // Along the vertical axis: the nested pair stacks two minimums plus its divider,
        // and the whole split adds another divider to the third pane's minimum.
        let expected = (SplitGeometry.minimumPaneLength * 2 + SplitGeometry.dividerWidth) + SplitGeometry.dividerWidth + SplitGeometry.minimumPaneLength
        XCTAssertEqual(SplitGeometry.minimumLength(of: layout, vertical: true), expected)
    }

    // MARK: - clampedRatio

    func testClampedRatioFollowsOffset() {
        // 608 = 200 + 8 + 400: the first pane may shrink to 200, the second to 200.
        let length: CGFloat = 608
        // The pointer's offset includes the divider's leading half: (308 - 4) / 608 = 0.5.
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 308, length: length, cut: twoPanesHorizontal) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 0, length: length, cut: twoPanesHorizontal) ?? -1, 200.0 / 608.0, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 608, length: length, cut: twoPanesHorizontal) ?? -1, 1 - 200.0 / 608.0, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 0, length: length, cut: twoPanesHorizontal) ?? -1, 200.0 / 608.0, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 608, length: length, cut: twoPanesHorizontal) ?? -1, 1 - 200.0 / 608.0, accuracy: 1e-9)
    }

    func testClampedRatioClampsToPaneMinimums() {
        let length: CGFloat = 408 // 200 + 8 + 200
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 0, length: length, cut: twoPanesHorizontal) ?? -1, 200.0 / 408.0, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampedRatio(offset: 408, length: length, cut: twoPanesHorizontal) ?? -1, 1 - 200.0 / 408.0, accuracy: 1e-9)
    }

    func testClampedRatioNilWithoutRoomOrLeaf() {
        // Too short for two minimum panes: the clamp has no room.
        XCTAssertNil(SplitGeometry.clampedRatio(offset: 0, length: 100, cut: twoPanesHorizontal))
        XCTAssertNil(SplitGeometry.clampedRatio(offset: 0, length: 100, cut: .pane(tabId: a)))
    }

    // MARK: - handleStrip

    func testHandleStripCapsAtPaneHeight() {
        XCTAssertEqual(
            SplitGeometry.handleStrip(in: CGRect(x: 10, y: 20, width: 100, height: 200), revealHeight: 48),
            CGRect(x: 10, y: 172, width: 100, height: 48)
        )
        XCTAssertEqual(
            SplitGeometry.handleStrip(in: CGRect(x: 10, y: 20, width: 100, height: 30), revealHeight: 48),
            CGRect(x: 10, y: 20, width: 100, height: 30)
        )
    }

    // MARK: - neighborPane

    func testNeighborPaneLeftRightUpDown() {
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 200),
            b: CGRect(x: 100, y: 0, width: 100, height: 100),
            c: CGRect(x: 100, y: 100, width: 100, height: 100)
        ]
        XCTAssertEqual(SplitGeometry.neighborPane(of: a, in: frames, direction: .right), b)
        XCTAssertEqual(SplitGeometry.neighborPane(of: b, in: frames, direction: .left), a)
        XCTAssertEqual(SplitGeometry.neighborPane(of: b, in: frames, direction: .down), c)
        XCTAssertEqual(SplitGeometry.neighborPane(of: c, in: frames, direction: .up), b)
        XCTAssertEqual(SplitGeometry.neighborPane(of: a, in: frames, direction: .up), nil)
        XCTAssertEqual(SplitGeometry.neighborPane(of: a, in: frames, direction: .down), nil)
    }

    func testNeighborPanePicksLargestOverlapThenTopmost() {
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 200),
            b: CGRect(x: 100, y: 0, width: 100, height: 50),
            c: CGRect(x: 100, y: 50, width: 100, height: 150)
        ]
        // Both reach a's right edge; the topmost one (b, the nearer edge) wins.
        XCTAssertEqual(SplitGeometry.neighborPane(of: a, in: frames, direction: .right), b)
    }

    func testNeighborPaneIgnoresNonReachingCandidates() {
        // b sits far to the right without touching a's edge, and no vertical overlap anyway.
        let frames: [UUID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 100, height: 100),
            b: CGRect(x: 300, y: 300, width: 100, height: 100)
        ]
        XCTAssertEqual(SplitGeometry.neighborPane(of: a, in: frames, direction: .right), nil)
    }

    func testNeighborPaneOfUnknownTabIsNil() {
        XCTAssertEqual(SplitGeometry.neighborPane(of: UUID(), in: [:], direction: .left), nil)
    }

    // MARK: - isEdgeDrop

    func testEdgeDropBands() {
        let pane = CGRect(x: 0, y: 0, width: 300, height: 100)
        XCTAssertTrue(SplitGeometry.isEdgeDrop(local: CGPoint(x: 10, y: 50), pane: pane))
        XCTAssertTrue(SplitGeometry.isEdgeDrop(local: CGPoint(x: 295, y: 50), pane: pane))
        XCTAssertFalse(SplitGeometry.isEdgeDrop(local: CGPoint(x: 150, y: 50), pane: pane))
        // A narrow pane's band is a sixth of its width.
        let narrow = CGRect(x: 0, y: 0, width: 60, height: 100)
        XCTAssertTrue(SplitGeometry.isEdgeDrop(local: CGPoint(x: 8, y: 50), pane: narrow))
        XCTAssertFalse(SplitGeometry.isEdgeDrop(local: CGPoint(x: 40, y: 50), pane: narrow))
    }

    // MARK: - SplitDropSide

    func testSplitDropSideParsesChromeZoneNames() {
        XCTAssertEqual(SplitDropSide("left")?.isReplace, false)
        XCTAssertEqual(SplitDropSide("right")?.isReplace, false)
        XCTAssertEqual(SplitDropSide("top")?.isReplace, false)
        XCTAssertEqual(SplitDropSide("bottom")?.isReplace, false)
        XCTAssertEqual(SplitDropSide("replace")?.isReplace, true)
        XCTAssertNil(SplitDropSide("diagonal"))
        XCTAssertNil(SplitDropSide(nil))
    }
}

/// The drop-side enum carries no payload to compare from a test, so each case answers one.
extension SplitDropSide {
    var isReplace: Bool { if case .replace = self { return true }; return false }
}
