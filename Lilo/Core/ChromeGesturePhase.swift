import Foundation

/// The gesture phase of a scroll / zoom / rotate / swipe event, collapsed from the event's
/// phase and momentum phase. `momentumBegan` is the first inertial event after the fingers lift.
enum ChromeGesturePhase: Equatable {
    case began
    case changed
    case ended
    case cancelled
    case momentumBegan
    case none
}

/// A raw event phase, mirroring `NSEvent.Phase` without AppKit.
enum ChromeRawPhase: Equatable {
    case began
    case changed
    case stationary
    case ended
    case cancelled
    /// Any phase the mapping does not name (a repeated event, an unknown value).
    case other
}

extension ChromeGesturePhase {
    /// The single raw-phase-to-gesture-phase mapping. Momentum arrives after the phase has ended:
    /// its `.began` relatches to the surface the fling started on, its `.ended` releases.
    static func resolve(phase: ChromeRawPhase, momentumPhase: ChromeRawPhase) -> ChromeGesturePhase {
        switch phase {
        case .began:
            return .began
        case .changed, .stationary:
            return .changed
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        case .other:
            switch momentumPhase {
            case .began:
                return .momentumBegan
            case .changed, .stationary:
                return .changed
            case .ended, .cancelled:
                return .ended
            case .other:
                return .none
            }
        }
    }
}
