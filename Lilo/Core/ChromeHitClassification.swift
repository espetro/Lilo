import Foundation

/// The pure hit-classification rules of the chrome / content boundary. The router supplies what it
/// knows (a zone hit, a content view, a modal page, a drag routed elsewhere) and gets the surface
/// the event belongs to; nothing here reads AppKit.
enum ChromeHitClassification {
    /// The classification for a pointer event: `.chrome` inside a zone the chrome registered,
    /// else `.content` when something shows in the content area, else `.none`.
    static func target(isOverChromeZone: Bool, hasContent: Bool) -> ChromeEventTarget {
        if isOverChromeZone { return .chrome }
        return hasContent ? .content : .none
    }

    /// The classification for a drag: the chrome wins over the content when the pointer is in a
    /// chrome zone or when the window hands the drag over, and a page under its tab-modal dialog
    /// takes no drop.
    static func dragTarget(
        isOverChromeZone: Bool,
        routesToChrome: Bool,
        hasContent: Bool,
        contentIsModal: Bool
    ) -> ChromeEventTarget {
        if isOverChromeZone || routesToChrome { return .chrome }
        guard hasContent, !contentIsModal else { return .none }
        return .content
    }
}
