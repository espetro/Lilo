import AppKit

extension NSWindow {
    /// Orders the window in where nobody sees it: transparent and past every display's edge.
    /// Ordering in is what `isVisible` reports and what WebKit's occlusion detection, popovers
    /// and the event paths under test count on; only the pixels stay off screen.
    @MainActor
    func orderFrontOffscreen(frame: NSRect? = nil) {
        var target = frame ?? self.frame
        target.origin = NSPoint(x: -20000, y: -20000)
        setFrame(target, display: false)
        alphaValue = 0
        orderFrontRegardless()
    }
}
