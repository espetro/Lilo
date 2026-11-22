import Foundation
import GRDB

/// Reads another Lilo build's data: `global.db` holds the spaces, each profile's `lilo.db` their
/// sidebar trees, history and favicons. Every file is read on a copy (`ImportFiles.withCopy`), so a
/// running source build is never disturbed and never written to.
enum LiloReader {
    /// `profile.url` is the sibling's `Profiles/<id>` directory, `global` its `global.db`. The
    /// extensions the scan found on the profile are reinstalled by id, like the other sources.
    static func read(profile: ImportProfile, kinds: Set<ImportKind>, global: URL) -> ImportReadResult {
        var result = ImportReadResult()
        let database = profile.url.appendingPathComponent("lilo.db")
        if kinds.contains(.bookmarks) || kinds.contains(.tabs) {
            do {
                result.bundle.spaces = try spaces(profile: profile, global: global, database: database,
                                                  bookmarked: kinds.contains(.bookmarks), tabs: kinds.contains(.tabs))
            } catch {
                // One read serves both kinds: a failure is reported on each the user asked for.
                let cause = ImportError.cause(of: error, "Reading lilo spaces")
                if kinds.contains(.bookmarks) { result.errors[.bookmarks] = cause }
                if kinds.contains(.tabs) { result.errors[.tabs] = cause }
            }
        }
        if kinds.contains(.history) {
            result.attempt(.history) { bundle in
                bundle.history = try ImportFiles.withCopy(database) { db in
                    try Row.fetchAll(db, sql: """
                        SELECT url, title, visitCount, lastVisitedAt FROM history
                        ORDER BY lastVisitedAt DESC LIMIT ?
                        """, arguments: [HistoryStore.maxRows]).map {
                        ImportedVisit(url: $0["url"], title: $0["title"], visitCount: $0["visitCount"], lastVisitedAt: $0["lastVisitedAt"])
                    }
                }
            }
        }
        if kinds.contains(.extensions) {
            result.bundle.extensions = profile.extensions
        }
        let hosts = ImportFiles.hosts(in: result.bundle.spaces.flatMap { $0.pinned + $0.unpinned + $0.bookmarked })
        if !hosts.isEmpty {
            result.bundle.favicons = (try? ImportFiles.withCopy(database) { db in
                try Row.fetchAll(db, sql: """
                    SELECT host, dataURL, dominantColor FROM favicons
                    WHERE host IN (\(databaseQuestionMarks(count: hosts.count)))
                    """, arguments: StatementArguments(Array(hosts))).map {
                    FaviconStore.Entry(host: $0["host"], dataURL: $0["dataURL"], dominantColor: $0["dominantColor"])
                }
            }) ?? []
        }
        return result
    }

    /// The spaces `global.db` lists for the profile, each filled from its `spaceTabStates` row.
    /// Private spaces stay out: their data is meant to be ephemeral. A row Lilo cannot decode is
    /// skipped, as `SpaceTabStateStore.load` would quarantine it in the source.
    private static func spaces(profile: ImportProfile, global: URL, database: URL,
                               bookmarked: Bool, tabs: Bool) throws -> [ImportedSpace] {
        let rows = try ImportFiles.withCopy(global) { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, icon, color FROM spaces
                WHERE profileId = ? AND isPrivate = 0 ORDER BY sortOrder
                """, arguments: [profile.id])
        }
        guard !rows.isEmpty else { return [] }
        return try ImportFiles.withCopy(database) { db in
            try rows.compactMap { row -> ImportedSpace? in
                let id: String = row["id"]
                guard let state = try storedState(spaceId: id, db: db) else { return nil }
                return ImportedSpace(name: row["name"], icon: row["icon"], color: row["color"],
                                     pinned: tabs ? bookmarks(state.tree.pinned) : [],
                                     unpinned: tabs ? bookmarks(state.tree.unpinned) : [],
                                     bookmarked: bookmarked ? bookmarks(state.tree.bookmarked) : [])
            }
        }
    }

    private static func storedState(spaceId: String, db: Database) throws -> SpaceTabState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT version, codec, state FROM spaceTabStates WHERE spaceId = ?",
                                         arguments: [spaceId]) else { return nil }
        let version: Int = row["version"]
        let codec: String = row["codec"]
        guard version <= SpaceTabState.currentVersion, codec == SpaceTabStateCodec.codec,
              let data: Data = row["state"], let state = try? SpaceTabStateCodec.decode(data) else { return nil }
        return state
    }

    /// Non-web tabs (terminals, agents) carry no http URL and stay behind.
    private static func bookmarks(_ nodes: [StoredSidebarNode]) -> [ImportedBookmark] {
        nodes.compactMap { node in
            switch node {
            case let .tab(tab):
                guard let url = tab.url ?? tab.homeURL, url.hasPrefix("http") else { return nil }
                return ImportedBookmark(title: tab.customTitle ?? tab.title, url: url)
            case let .folder(folder):
                if let layout = folder.splitLayout {
                    var vertical = false
                    if case let .split(root, _, _, _) = layout { vertical = root }
                    return ImportedBookmark(title: "", url: nil, children: bookmarks(folder.children), splitVertical: vertical)
                }
                return ImportedBookmark(title: folder.name, url: nil, children: bookmarks(folder.children), color: folder.color)
            }
        }
    }
}
