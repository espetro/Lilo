import AppKit
import XCTest
@testable import Lilo

/// Trackpad gestures drive the floating panels: a pan over the chrome - or anywhere with Option
/// held - moves the window, a pinch resizes it keeping its aspect, and a pan over the page still
/// scrolls the page.
@MainActor
final class PiPGesturePanelTests: XCTestCase {
    private var panel: PiPGesturePanel!
    private var spy: GestureSpy!

    override func setUp() {
        super.setUp()
        panel = PiPGesturePanel(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        spy = GestureSpy(frame: NSRect(origin: .zero, size: NSSize(width: 320, height: 200)))
        panel.contentView?.addSubview(spy)
        // Transparent but in place: the synthesized events must land on the panel's real frame.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        addTeardownBlock { [panel] in panel?.orderOut(nil) }
    }

    /// A scroll CGEvent over the panel, as a trackpad writes one: continuous, phased. `window`
    /// makes its NSEvent read `locationInWindow` in this panel's coordinates.
    private func scroll(dx: Int32, dy: Int32, at point: NSPoint, phase: Int64 = 2, momentum: Int64 = 0, option: Bool = false) throws -> NSEvent {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0
        ), let screen = NSScreen.screens.first else { throw XCTSkip("no scroll event") }
        // The NSEvent has no window: `locationInWindow` reads the flipped global point as-is,
        // so give it the point a real event would read in the window's coordinates.
        cgEvent.location = CGPoint(x: point.x, y: screen.frame.height - point.y)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(panel.windowNumber))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        if momentum > 0 { cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum) }
        if option { cgEvent.flags = .maskAlternate }
        guard let event = NSEvent(cgEvent: cgEvent) else { throw XCTSkip("no NSEvent") }
        return event
    }

    func testAPanOverThePageScrollsThePageAndLeavesTheWindow() throws {
        let event = try scroll(dx: 0, dy: -8, at: NSPoint(x: 160, y: 100), phase: 1)

        panel.sendEvent(event)

        XCTAssertTrue(spy.scrolled, "a pan over the page reaches the view under the pointer")
        XCTAssertEqual(panel.frame, NSRect(x: 200, y: 200, width: 320, height: 200),
                       "a page-bound pan never moves the window")
    }

    func testAPanOverThePageWithOptionHeldMovesTheWindow() throws {
        let event = try scroll(dx: 0, dy: 10, at: NSPoint(x: 160, y: 100), phase: 1, option: true)

        panel.sendEvent(event)

        XCTAssertFalse(spy.scrolled)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 210),
                       "with Option the pan moves the window with the fingers")
    }

    func testAPanOverTheDragRegionMovesTheWindowWithoutAModifier() throws {
        let region = DragRegionView(frame: NSRect(x: 0, y: 172, width: 320, height: 28))
        panel.contentView?.addSubview(region)
        let event = try scroll(dx: 8, dy: -4, at: NSPoint(x: 160, y: 186), phase: 1)

        panel.sendEvent(event)

        XCTAssertEqual(panel.frame.origin, NSPoint(x: 208, y: 196),
                       "a pan over the panel's chrome moves the window")
    }

    func testAMouseWheelScrollsThePageEvenOverTheDragRegion() throws {
        let region = DragRegionView(frame: NSRect(x: 0, y: 172, width: 320, height: 28))
        panel.contentView?.addSubview(region)
        // No phase, no continuous flag: a wheel, not a gesture.
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -8, wheel2: 0, wheel3: 0
        ), let screen = NSScreen.screens.first else { throw XCTSkip("no scroll event") }
        cgEvent.location = CGPoint(x: 160, y: screen.frame.height - 186)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(panel.windowNumber))
        guard let event = NSEvent(cgEvent: cgEvent) else { throw XCTSkip("no NSEvent") }

        panel.sendEvent(event)

        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 200), "a mouse wheel never moves the window")
    }

    func testEndingAMovePanFiresTheEndedHookOnceAndSwallowsMomentum() throws {
        var ended = 0
        panel.onGestureMoveEnded = { ended += 1 }
        let begin = try scroll(dx: 0, dy: 10, at: NSPoint(x: 160, y: 100), phase: 1, option: true)
        let end = try scroll(dx: 0, dy: 0, at: NSPoint(x: 160, y: 100), phase: 4, option: true)
        let momentum = try scroll(dx: 0, dy: -30, at: NSPoint(x: 160, y: 100), phase: 0, momentum: 2, option: true)

        panel.sendEvent(begin)
        panel.sendEvent(end)
        panel.sendEvent(momentum)

        XCTAssertEqual(ended, 1, "the snap hook runs once, as the gesture ends")
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 200, y: 210),
                       "the momentum tail does not coast the window")
    }

    func testEndingAPagePanDeliversTheEndToThePage() throws {
        let begin = try scroll(dx: 0, dy: -8, at: NSPoint(x: 160, y: 100), phase: 1)
        let end = try scroll(dx: 0, dy: 0, at: NSPoint(x: 160, y: 100), phase: 4)

        panel.sendEvent(begin)
        panel.sendEvent(end)

        XCTAssertEqual(spy.scrolls, 2, "the page sees the gesture end")
    }

    func testAPinchResizesKeepingAspectAboutTheCenter() throws {
        panel.resize(byMagnification: 0.5)

        let frame = panel.frame
        XCTAssertEqual(frame.size, NSSize(width: 480, height: 300), "the pinch scales both ways")
        XCTAssertEqual(frame.midX, 360, accuracy: 0.5, "the window grows about its center")
        XCTAssertEqual(frame.midY, 300, accuracy: 0.5)
    }

    func testAPinchOutRespectsTheMinimumSizeAndAspect() throws {
        panel.contentMinSize = NSSize(width: 160, height: 120)

        panel.resize(byMagnification: -0.9)

        XCTAssertEqual(panel.frame.size.height, 120, accuracy: 0.5)
        XCTAssertEqual(panel.frame.size.width / panel.frame.size.height, 320.0 / 200.0, accuracy: 0.01,
                       "the clamp scales the pinch, never one side alone")
    }

    func testAPinchInNeverCoversHalfTheScreenAndStaysInsideIt() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        // Near the corner: the unclamped growth would push the window past the edge.
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 4,
                                     y: screen.visibleFrame.maxY - panel.frame.height - 4))

        panel.resize(byMagnification: 20)

        XCTAssertLessThanOrEqual(panel.frame.width, (screen.visibleFrame.width / 2).rounded(.down) + 0.5)
        XCTAssertLessThanOrEqual(panel.frame.height, (screen.visibleFrame.height / 2).rounded(.down) + 0.5)
        XCTAssertLessThanOrEqual(panel.frame.maxX, screen.visibleFrame.maxX + 0.5,
                                 "the clamped window stays inside the screen")
        XCTAssertLessThanOrEqual(panel.frame.maxY, screen.visibleFrame.maxY + 0.5)
    }

    func testAPlainClickStillReachesTheContent() throws {
        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                    mouseCursorPosition: .zero, mouseButton: .left),
              let screen = NSScreen.screens.first else { throw XCTSkip("no mouse event") }
        cgEvent.location = CGPoint(x: 160, y: screen.frame.height - 100)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(panel.windowNumber))
        guard let event = NSEvent(cgEvent: cgEvent) else { throw XCTSkip("no NSEvent") }

        panel.sendEvent(event)

        XCTAssertTrue(spy.mouseDown, "an ordinary click keeps working")
    }
}

/// Opaque as the hosted web view is: the view a trackpad pan would drag the window from.
private final class GestureSpy: NSView {
    private(set) var scrolled = false
    private(set) var scrolls = 0
    private(set) var mouseDown = false
    override var isOpaque: Bool { true }
    override func scrollWheel(with event: NSEvent) { scrolled = true; scrolls += 1 }
    override func mouseDown(with event: NSEvent) { mouseDown = true }
}

/// The hover chrome a pan drags the window by.
private final class DragRegionView: NSView, PiPWindowDragRegion {}
