import Foundation

/// Which surface an input event belongs to: the chrome overlay, the content area, or neither
/// (nothing in the content area). The single classification the hover and capture machines speak.
enum ChromeEventTarget: Equatable {
    case chrome
    case content
    case none
}

/// The `NSEvent` families the chrome router can see, collapsed from `NSEvent.EventType` so the
/// routing core never reads `NSEvent` itself.
enum ChromeEventFamily {
    case leftMouseDown
    case leftMouseDragged
    case leftMouseUp
    case rightMouseDown
    case rightMouseDragged
    case rightMouseUp
    case otherMouseDown
    case otherMouseDragged
    case otherMouseUp
    case cursorUpdate
    case scrollWheel
    case magnify
    case rotate
    case swipe
    case smartMagnify
}
