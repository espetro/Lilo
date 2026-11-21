import AppKit
import XCTest
@testable import Lilo

@MainActor
final class HoldToQuitTests: XCTestCase {
    private var hold: HoldToQuit!
    private var enabled = true
    private var quits = 0
    /// The HUD centers over the event's window, else over the main screen: this one keeps it off the user's display.
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        enabled = true
        quits = 0
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontOffscreen()
        hold = HoldToQuit()
        hold.isEnabled = { [weak self] in self?.enabled == true }
        hold.quit = { [weak self] in self?.quits += 1 }
        hold.holdDuration = 0.02
    }

    override func tearDown() {
        KeyboardShortcuts.applyPreset("lilo", store: nil)
        hold = nil
        window.close()
        window = nil
        super.tearDown()
    }

    private func key(_ type: NSEvent.EventType, _ characters: String = "q",
                     _ flags: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 12, isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode)!
    }

    /// The hold's 20 ms timer fires late when the test workers saturate the Mac: wait for it, not for a fixed 100 ms.
    private func runUntilQuit() {
        let deadline = Date().addingTimeInterval(5)
        while quits == 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testTheQuitKeyReachesTheMenusWhileOff() {
        enabled = false
        XCTAssertFalse(hold.handle(key(.keyDown)))
        XCTAssertFalse(hold.handle(key(.keyUp)))
        XCTAssertFalse(hold.isHolding)
    }

    func testAPressBeginsAHoldAndItsRepeatStaysSwallowed() {
        XCTAssertTrue(hold.handle(key(.keyDown)))
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.handle(key(.keyDown, isRepeat: true)))
        XCTAssertTrue(hold.isHolding)
    }

    func testReleasingTheKeyCancelsTheHold() {
        _ = hold.handle(key(.keyDown))
        XCTAssertTrue(hold.handle(key(.keyUp)))
        XCTAssertFalse(hold.isHolding)
    }

    func testReleasingCommandCancelsTheHold() {
        _ = hold.handle(key(.keyDown))
        XCTAssertFalse(hold.handle(key(.flagsChanged, "", [])))
        XCTAssertFalse(hold.isHolding)
    }

    func testAnUnrelatedKeyReleaseKeepsTheHold() {
        _ = hold.handle(key(.keyDown))
        XCTAssertFalse(hold.handle(key(.keyUp, "x", .command, keyCode: 7)))
        XCTAssertTrue(hold.isHolding)
    }

    func testHoldingThroughTheDeadlineQuitsOnce() {
        _ = hold.handle(key(.keyDown))
        runUntilQuit()
        XCTAssertEqual(quits, 1)
        XCTAssertFalse(hold.isHolding)
        // The keys are still down: their repeats must not begin a second hold.
        XCTAssertTrue(hold.handle(key(.keyDown, isRepeat: true)))
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(quits, 1)
    }

    func testAFreshPressAfterACancelledQuitBeginsANewHold() {
        _ = hold.handle(key(.keyDown))
        runUntilQuit()
        XCTAssertEqual(quits, 1)
        // The termination was cancelled and the release went to another app: the next press still holds.
        XCTAssertTrue(hold.handle(key(.keyDown)))
        XCTAssertTrue(hold.isHolding)
    }

    func testAnExtraModifierThenReleasingTheKeyCancels() {
        _ = hold.handle(key(.keyDown))
        XCTAssertFalse(hold.handle(key(.flagsChanged, "", [.command, .shift])))
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.handle(key(.keyUp, "Q", [.command, .shift])))
        XCTAssertFalse(hold.isHolding)
    }

    func testLosingFocusCancelsTheHold() {
        _ = hold.handle(key(.keyDown))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(hold.isHolding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(quits, 0)
    }

    func testAReboundQuitShortcutHoldsAndCancelsOnItsOwnKeys() {
        KeyboardShortcuts.set("app.quit", to: ["⌥⇧k"], store: nil)
        XCTAssertTrue(hold.handle(key(.keyDown, "k", [.option, .shift], keyCode: 40)))
        XCTAssertTrue(hold.isHolding)
        // Letting a modifier of the combo go cancels.
        XCTAssertFalse(hold.handle(key(.flagsChanged, "", .shift)))
        XCTAssertFalse(hold.isHolding)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(quits, 0)
    }
}
