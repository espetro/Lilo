import XCTest
@testable import Lilo

/// Pure phase mapping, no windows: runs wherever `swift test` does.
final class ChromeGesturePhaseTests: XCTestCase {
    func testFingerPhaseMapsDirectly() {
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .began, momentumPhase: .other), .began)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .changed, momentumPhase: .other), .changed)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .stationary, momentumPhase: .other), .changed)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .ended, momentumPhase: .other), .ended)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .cancelled, momentumPhase: .other), .cancelled)
    }

    // Momentum arrives after the finger phase has ended (phase .other here): its .began
    // relatches, its .changed carries the fling, its .ended / .cancelled release.
    func testMomentumMapsWhenFingerPhaseIsOver() {
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .other, momentumPhase: .began), .momentumBegan)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .other, momentumPhase: .changed), .changed)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .other, momentumPhase: .stationary), .changed)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .other, momentumPhase: .ended), .ended)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .other, momentumPhase: .cancelled), .ended)
    }

    // A classic mouse-wheel line scroll: no phase and no momentum at all.
    func testPhaselessScrollIsNone() {
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .other, momentumPhase: .other), .none)
    }

    // A live finger phase wins over any lingering momentum phase.
    func testFingerPhaseBeatsMomentum() {
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .began, momentumPhase: .changed), .began)
        XCTAssertEqual(ChromeGesturePhase.resolve(phase: .ended, momentumPhase: .began), .ended)
    }
}
