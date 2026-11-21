import AppKit

/// A view under the pointer that a two-finger pan drags the window by instead of scrolling: the
/// chrome of a floating panel, like the PiP hover bar.
protocol PiPWindowDragRegion {}

/// The floating panels - Document PiP and a floated tab - move and resize like Arc's PiP window:
/// a trackpad pan over the window's chrome (or anywhere with Option held) moves it, a pinch
/// resizes it, and a pan over the page still scrolls the page. AppKit would already read a pan
/// starting over an opaque view as a window move; dispatching the gesture here is what lets a pan
/// over the page reach the page and a pinch anywhere resize instead of page-zooming.
@MainActor
class PiPGesturePanel: NSPanel {
    /// A pan that moved the window ended: where the panel snaps or persists its frame.
    var onGestureMoveEnded: (() -> Void)?

    /// Set per pan: whether its deltas move the window or scroll the page, kept so a gesture
    /// routed to the page keeps scrolling even as the pointer crosses the chrome.
    private var panMovesWindow: Bool?
    /// Whether the gesture that just ended moved the window, so its momentum tail is swallowed
    /// rather than coasting the page.
    private var lastPanMovedWindow = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel: handleScroll(event)
        case .magnify: resize(byMagnification: event.magnification)
        default: super.sendEvent(event)
        }
    }

    private func handleScroll(_ event: NSEvent) {
        if event.phase.isEmpty {
            // A mouse wheel has no phase and always scrolls the page; a pan's momentum tail keeps
            // scrolling what the pan scrolled - a page, never a coasting window.
            if event.momentumPhase.isEmpty || !lastPanMovedWindow { forwardScroll(event) }
            return
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            lastPanMovedWindow = panMovesWindow ?? false
            if lastPanMovedWindow { onGestureMoveEnded?() } else { forwardScroll(event) }
            panMovesWindow = nil
            return
        }
        if panMovesWindow == nil { panMovesWindow = shouldMoveWindow(for: event) }
        if panMovesWindow == true {
            // Natural scrolling reports the delta as the content's travel under the fingers:
            // adding it makes the window follow the fingers like a dragged sheet.
            setFrameOrigin(NSPoint(x: frame.origin.x + event.scrollingDeltaX,
                                   y: frame.origin.y + event.scrollingDeltaY))
        } else {
            forwardScroll(event)
        }
    }

    /// What a real dispatch would deliver to: the view under the pointer.
    private func forwardScroll(_ event: NSEvent) {
        guard let contentView,
              let view = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        else { return }
        view.scrollWheel(with: event)
    }

    private func shouldMoveWindow(for event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.option) { return true }
        guard let contentView,
              let view = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        else { return true } // a titled panel's frame, or the borderless panel's margin
        var target: NSView? = view
        while let current = target {
            if current is PiPWindowDragRegion { return true }
            target = unsafe current.superview
        }
        return false
    }

    /// Scales the frame about its center, keeping its aspect: the pinch factor is clamped between
    /// the content's minimum size and half the screen each way, as a PiP window never covers its
    /// screen, and the result is kept inside the visible frame.
    func resize(byMagnification magnification: CGFloat) {
        let scale = 1 + magnification
        let size = frame.size
        guard scale > 0, size.width > 0, size.height > 0 else { return }
        var low = contentMinSize.width / size.width
        low = max(low, contentMinSize.height / size.height)
        var high = CGFloat.greatestFiniteMagnitude
        if let visible = screen?.visibleFrame {
            high = min((visible.width / 2).rounded(.down) / size.width,
                       (visible.height / 2).rounded(.down) / size.height)
        }
        let clampedScale = max(low, min(scale, high))
        let clamped = NSSize(width: size.width * clampedScale, height: size.height * clampedScale)
        var resized = NSRect(x: frame.midX - clamped.width / 2, y: frame.midY - clamped.height / 2,
                             width: clamped.width, height: clamped.height)
        if let visible = screen?.visibleFrame {
            resized.origin.x = min(max(resized.origin.x, visible.minX), visible.maxX - resized.width)
            resized.origin.y = min(max(resized.origin.y, visible.minY), visible.maxY - resized.height)
        }
        setFrame(resized, display: true)
    }
}
