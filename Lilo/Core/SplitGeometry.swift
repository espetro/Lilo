import Foundation

/// Pure geometry for the split view: how a layout's cuts tile a rectangle into pane and
/// divider frames, how far each part can shrink along its cuts' axis, and which pane
/// abuts another's edge. No AppKit: everything speaks Core Graphics types.
enum SplitGeometry {
    /// The divider's gap between two panes, as the views draw it.
    static let dividerWidth: CGFloat = 8

    /// Smallest pane a divider drag may leave, along the axis of the cut.
    static let minimumPaneLength: CGFloat = 200

    /// One cut of a layout: the divider's frame, the cut's full bounds and its direction.
    struct Cut: Equatable {
        var divider: CGRect
        var bounds: CGRect
        var vertical: Bool
    }

    /// The layout's cut, or nil when `path` names a pane or nothing.
    static func cut(at path: [Bool], in layout: SplitLayout) -> SplitLayout? {
        guard case let .split(vertical, ratio, first, second) = layout.subtree(at: path) else { return nil }
        return .split(vertical: vertical, ratio: ratio, first: first, second: second)
    }

    /// Each pane's frame and each cut's divider frame and bounds, in `rect`'s coordinates.
    /// `first` of a cut is on top or to the left, whichever way `flipped` counts y.
    static func frames(
        _ layout: SplitLayout, in rect: CGRect, flipped: Bool, path: [Bool] = [],
        panes: inout [UUID: CGRect], cuts: inout [[Bool]: Cut]
    ) {
        guard case let .split(vertical, ratio, first, second) = layout else {
            if case let .pane(tabId) = layout { panes[tabId] = rect }
            return
        }
        let gap = Self.dividerWidth
        let firstRect: CGRect, divider: CGRect, secondRect: CGRect
        if vertical {
            let firstHeight = ((rect.height - gap) * CGFloat(ratio)).rounded()
            let secondHeight = rect.height - firstHeight - gap
            // First on top, whichever way the container counts y.
            firstRect = CGRect(x: rect.minX, y: flipped ? rect.minY : rect.maxY - firstHeight, width: rect.width, height: firstHeight)
            divider = CGRect(x: rect.minX, y: flipped ? rect.minY + firstHeight : rect.minY + secondHeight, width: rect.width, height: gap)
            secondRect = CGRect(x: rect.minX, y: flipped ? rect.maxY - secondHeight : rect.minY, width: rect.width, height: secondHeight)
        } else {
            let firstWidth = ((rect.width - gap) * CGFloat(ratio)).rounded()
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            divider = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: gap, height: rect.height)
            secondRect = CGRect(x: divider.maxX, y: rect.minY, width: rect.maxX - divider.maxX, height: rect.height)
        }
        cuts[path] = Cut(divider: divider, bounds: rect, vertical: vertical)
        frames(first, in: firstRect, flipped: flipped, path: path + [false], panes: &panes, cuts: &cuts)
        frames(second, in: secondRect, flipped: flipped, path: path + [true], panes: &panes, cuts: &cuts)
    }

    /// Panes and cuts at once, for callers that need the whole tiling.
    static func frames(_ layout: SplitLayout, in rect: CGRect, flipped: Bool) -> (panes: [UUID: CGRect], cuts: [[Bool]: Cut]) {
        var panes: [UUID: CGRect] = [:]
        var cuts: [[Bool]: Cut] = [:]
        frames(layout, in: rect, flipped: flipped, panes: &panes, cuts: &cuts)
        return (panes, cuts)
    }

    /// How short a part can get along a cut's axis: its panes' minimum, plus the dividers
    /// between panes stacked along that same axis.
    static func minimumLength(of layout: SplitLayout, vertical: Bool) -> CGFloat {
        guard case let .split(isVertical, _, first, second) = layout else { return minimumPaneLength }
        let firstLength = minimumLength(of: first, vertical: vertical)
        let secondLength = minimumLength(of: second, vertical: vertical)
        return isVertical == vertical ? firstLength + dividerWidth + secondLength : max(firstLength, secondLength)
    }

    /// The divider ratio a pointer at `offset` along the cut leaves, clamped to how short
    /// either part may get. `length` is the cut's span minus the divider. Nil when the clamp
    /// has no room (a part is already at its minimum on both ends) or the cut is a leaf.
    static func clampedRatio(offset: CGFloat, length: CGFloat, cut: SplitLayout) -> Double? {
        guard length > 0, case let .split(vertical, _, first, second) = cut else { return nil }
        let lowest = minimumLength(of: first, vertical: vertical) / length
        let highest = 1 - minimumLength(of: second, vertical: vertical) / length
        guard lowest <= highest else { return nil }
        return Double(min(max((offset - dividerWidth / 2) / length, lowest), highest))
    }

    /// The strip of `pane`'s top edge where the pointer reveals the pane's handle.
    static func handleStrip(in pane: CGRect, revealHeight: CGFloat) -> CGRect {
        let height = min(revealHeight, pane.height)
        return CGRect(x: pane.minX, y: pane.maxY - height, width: pane.width, height: height)
    }

    /// The pane abutting `frame` on `direction`'s side, in top-left-origin shares: the one
    /// with the largest overlap across the frame and the nearest reaching edge. Used by the
    /// menu's pane moves; a drag aims by edge instead.
    static func neighborPane(of tabId: UUID, in frames: [UUID: CGRect], direction: SplitPaneDirection) -> UUID? {
        guard let frame = frames[tabId] else { return nil }
        var best: (id: UUID, edge: CGFloat, cross: CGFloat)?
        for (id, cand) in frames where id != tabId {
            let overlap: CGFloat, edge: CGFloat, cross: CGFloat, reaches: Bool
            switch direction {
            case .left:
                overlap = min(frame.maxY, cand.maxY) - max(frame.minY, cand.minY)
                edge = cand.maxX; cross = cand.minY
                reaches = cand.maxX <= frame.minX + 0.002
            case .right:
                overlap = min(frame.maxY, cand.maxY) - max(frame.minY, cand.minY)
                edge = -cand.minX; cross = cand.minY
                reaches = cand.minX >= frame.maxX - 0.002
            case .up:
                overlap = min(frame.maxX, cand.maxX) - max(frame.minX, cand.minX)
                edge = cand.maxY; cross = cand.minX
                reaches = cand.maxY <= frame.minY + 0.002
            case .down:
                overlap = min(frame.maxX, cand.maxX) - max(frame.minX, cand.minX)
                edge = -cand.minY; cross = cand.minX
                reaches = cand.minY >= frame.maxY - 0.002
            }
            guard overlap > 0, reaches else { continue }
            if let current = best, edge < current.edge || (edge == current.edge && cross >= current.cross) { continue }
            best = (id, edge, cross)
        }
        return best?.id
    }

    /// A web link dragged from outside the pages lands on the chrome when it sits in a narrow
    /// strip at a pane's left or right edge; the rest of the pane keeps the drop for the page.
    static func isEdgeDrop(local: CGPoint, pane: CGRect) -> Bool {
        let band = min(pane.width / 6, 64)
        return local.x < pane.minX + band || local.x > pane.maxX - band
    }
}

/// A pane move's direction, as the menu item's tag carries it.
enum SplitPaneDirection: Int {
    case left, right, up, down
}

/// Where a tab dropped on the page lands: on one edge of a pane, or in its place.
enum SplitDropSide {
    case edge(vertical: Bool, before: Bool)
    case replace

    /// The chrome's drop zone names: left, right, top, bottom or replace.
    init?(_ name: String?) {
        switch name {
        case "left": self = .edge(vertical: false, before: true)
        case "right": self = .edge(vertical: false, before: false)
        case "top": self = .edge(vertical: true, before: true)
        case "bottom": self = .edge(vertical: true, before: false)
        case "replace": self = .replace
        default: return nil
        }
    }
}
