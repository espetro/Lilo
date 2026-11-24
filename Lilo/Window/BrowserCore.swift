import Foundation

/// Browser-state sync logic that speaks only the bridge payload protocol: plain
/// dictionaries keyed by `TabBridgeField`, no AppKit, no views. A window feeds it
/// payloads and ships the returned events; the patch bookkeeping lives here.
///
/// Modeled on TabLayout: pure, unit-testable, portable off macOS.
struct BrowserCore {
    /// Tab payloads by id as the chrome last received them through `tabUpdated`. Every other
    /// event that seeds a tab's state clears the entry, so the next patch after it is complete.
    var sentTabPatches: [String: [String: Any]] = [:]

    /// The event to send for a tab payload: only the fields that differ from what the chrome
    /// last received for the tab, or nil when nothing differs. The caller owns the sending.
    mutating func tabUpdateEvent(_ tabPayload: [String: Any], spaceId: UUID) -> BrowserChangePresenter.Event? {
        guard let id = tabPayload[TabBridgeField.id.rawValue] as? String else { return nil }
        var patch = tabPayload
        if let sent = sentTabPatches[id] {
            patch = [TabBridgeField.id.rawValue: id]
            for (key, value) in tabPayload where (sent[key] as? AnyHashable) != (value as? AnyHashable) {
                patch[key] = value
            }
            guard patch.count > 1 else { return nil }
            // The chrome falls back to the url for a blank title.
            if patch[TabBridgeField.title.rawValue] != nil {
                patch[TabBridgeField.url.rawValue] = tabPayload[TabBridgeField.url.rawValue]
            }
        }
        sentTabPatches[id, default: [:]].merge(tabPayload) { $1 }
        return BrowserChangePresenter.tabUpdatedEvent(tabPayload: patch, spaceId: spaceId)
    }

    /// A sidebar patch reseeds only the tabs it upserts or removes.
    mutating func clearSentTabPatches(in operations: [[String: Any]]) {
        for operation in operations {
            for tab in operation["upsertTabs"] as? [[String: Any]] ?? [] {
                if let id = tab[TabBridgeField.id.rawValue] as? String { sentTabPatches[id] = nil }
            }
            for id in operation["removedTabIds"] as? [String] ?? [] { sentTabPatches[id] = nil }
        }
    }

    mutating func clearAllSentTabPatches() {
        sentTabPatches.removeAll(keepingCapacity: true)
    }
}
