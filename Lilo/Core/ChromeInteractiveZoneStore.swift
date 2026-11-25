import Foundation

/// Native source of truth for chrome-owned interactive rects.
final class ChromeInteractiveZoneStore {
    private var zones: [String: NSRect] = [:]
    var onZonesChanged: (([String: NSRect]) -> Void)?

    /// One frame's worth of moved zones (a window or sidebar resize moves them all): one fanout.
    func registerZones(_ batch: [(id: String, rect: NSRect)]) {
        assert(Thread.isMainThread)
        var changed = false
        for zone in batch where zones[zone.id] != zone.rect {
            zones[zone.id] = zone.rect
            changed = true
        }
        if changed { onZonesChanged?(zones) }
    }

    func removeZone(id: String) {
        assert(Thread.isMainThread)
        zones.removeValue(forKey: id)
        onZonesChanged?(zones)
    }

    func currentZones() -> [String: NSRect] {
        assert(Thread.isMainThread)
        return zones
    }

    func isInteractive(_ point: NSPoint, in bounds: NSRect, isFlipped: Bool = false) -> Bool {
        assert(Thread.isMainThread)
        let viewportPoint = viewportPoint(from: point, in: bounds, isFlipped: isFlipped)
        // O(zones): ~6 rects, linear contains. Deliberately not spatially indexed
        // (YAGNI at this size). Do not "optimize" blindly.
        return zones.values.contains { $0.contains(viewportPoint) }
    }

    func zoneId(at point: NSPoint, in bounds: NSRect, isFlipped: Bool = false) -> String? {
        assert(Thread.isMainThread)
        let viewportPoint = viewportPoint(from: point, in: bounds, isFlipped: isFlipped)
        return zones.first { $0.value.contains(viewportPoint) }?.key
    }

    func viewportPoint(from point: NSPoint, in bounds: NSRect, isFlipped: Bool) -> NSPoint {
        isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
    }
}
