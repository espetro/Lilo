import Foundation

/// Browser-state sync logic that speaks only the bridge payload protocol: plain
/// dictionaries keyed by `TabBridgeField`, no AppKit, no views. A window feeds it
/// payloads and ships the returned events; the patch bookkeeping lives here.
///
/// Modeled on TabLayout: pure, unit-testable, portable off macOS.
struct BrowserCore {
    /// What the command application needs to know about a tab before mutating.
    struct TabFacts {
        var kind: Tab.Kind
        var isPinned: Bool
        var isClosed: Bool
        var isBookmarked: Bool
    }

    /// The side work `applyBrowserCommand` does around the store's mutation, classified
    /// before it runs so the mutation itself stays the coordinator's.
    struct BrowserCommandEffects {
        /// A closed terminal tab whose saved screen goes with it.
        var closingTerminalTabId: UUID?
        /// The pinned state before the command, for extension notifications on change.
        var previousPinnedState: Bool?
        /// A closed pinned or bookmarked tab the command takes out of the sidebar.
        var removedTabId: UUID?
        /// A folder deleted with its tabs: space and the tabs that were inside it.
        var deletedFolderSpaceId: UUID?
        var deletedFolderTabIds: Set<UUID> = []
    }
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

    /// The side effects a browser command implies around its mutation. Pure: it reads the
    /// command and what is known about the tabs it touches, and runs nothing.
    static func effects(
        of command: BrowserCommand,
        tabFacts: (UUID) -> TabFacts?,
        folderTabIds: (UUID, UUID) -> Set<UUID>
    ) -> BrowserCommandEffects {
        var effects = BrowserCommandEffects()
        if case let .closeTab(_, tabId) = command, tabFacts(tabId)?.kind == .terminal {
            // A terminal closed for good takes its saved screen along, shown or not.
            effects.closingTerminalTabId = tabId
        }
        if case let .setPinned(_, tabId, _) = command {
            effects.previousPinnedState = tabFacts(tabId)?.isPinned
        }
        // Unpinning a closed pinned tab, or unbookmarking a closed bookmark, takes it out of the
        // sidebar: Undo and Reopen Closed Tab bring it back, whichever path removed it.
        if case let .setPinned(_, tabId, false) = command,
           let facts = tabFacts(tabId), facts.isClosed, facts.isPinned {
            effects.removedTabId = tabId
        }
        if case let .setBookmarked(_, tabId, false) = command,
           let facts = tabFacts(tabId), facts.isClosed, facts.isBookmarked {
            effects.removedTabId = tabId
        }
        if case let .deleteFolderWithTabs(spaceId, folderId) = command {
            // A folder deleted with its tabs takes their pages along, or one a window shows stays on screen.
            effects.deletedFolderSpaceId = spaceId
            effects.deletedFolderTabIds = folderTabIds(spaceId, folderId)
        }
        return effects
    }

    /// This space's slice of a runtime snapshot: the store-side snapshot to persist or hand over.
    /// The filtering is pure; the state comes from the caller's tab manager mirror. The snapshot
    /// type is MainActor-isolated (its engines only exist on the main actor), so is this.
    @MainActor
    static func spaceSnapshot(
        for spaceId: UUID, runtime: TabRuntimeSnapshot, state: SpaceTabState
    ) -> BrowserStateStore.SpaceSnapshot {
        let tabs = runtime.tabs.filter { $0.spaceId == spaceId }
        let tabIds = Set(tabs.map(\.id))
        return BrowserStateStore.SpaceSnapshot(
            spaceTab: SpaceTab(spaceId: spaceId, state: state),
            engines: runtime.engines.filter { tabIds.contains($0.key) },
            tabAdapters: runtime.tabAdapters.filter { tabIds.contains($0.key) },
            interactionStates: runtime.savedInteractionStates.filter { tabIds.contains($0.key) },
            restoringTabIds: runtime.restoringTabIds.filter { tabIds.contains($0.key) },
            lastAccessedAt: Date()
        )
    }
}
