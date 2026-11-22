import GRDB
import XCTest
@testable import Lilo

final class LiloReaderTests: XCTestCase {
    private var root: URL!
    private var profileDir: URL!
    private let profileId = UUID().uuidString
    private let spaceId = UUID().uuidString

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-source-\(UUID().uuidString)")
        profileDir = root.appendingPathComponent("Profiles/\(profileId)")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let global = try DatabaseQueue(path: root.appendingPathComponent("global.db").path)
        try global.write { db in
            try db.execute(sql: "CREATE TABLE profiles (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE installed_extensions (id TEXT NOT NULL, profile_id TEXT NOT NULL, name TEXT NOT NULL)")
            try db.execute(sql: """
                CREATE TABLE spaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT NOT NULL, color TEXT NOT NULL,
                    profileId TEXT NOT NULL, isPrivate INTEGER NOT NULL DEFAULT 0, sortOrder INTEGER NOT NULL DEFAULT 0)
                """)
            try db.execute(sql: "INSERT INTO profiles VALUES (?, 'Personal')", arguments: [profileId])
            try db.execute(sql: """
                INSERT INTO installed_extensions VALUES ('abcdefghijklmnopqrstuvwxyzabcde1', ?, 'Sample Blocker')
                """, arguments: [profileId])
        }
        let queue = try DatabaseQueue(path: profileDir.appendingPathComponent("lilo.db").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE spaceTabStates (spaceId TEXT PRIMARY KEY, version INTEGER NOT NULL,
                    codec TEXT NOT NULL, state BLOB NOT NULL, updatedAt DATETIME NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE history (id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL,
                    visitCount INTEGER NOT NULL, lastVisitedAt DATETIME NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE favicons (host TEXT PRIMARY KEY, dataURL TEXT NOT NULL, dominantColor TEXT)
                """)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var profile: ImportProfile {
        ImportProfile(id: profileId, name: "Personal", url: profileDir, kinds: ImportKind.allCases,
                      extensions: [ImportedExtension(id: "abcdefghijklmnopqrstuvwxyzabcde1", name: "Sample Blocker")])
    }

    private var global: URL { root.appendingPathComponent("global.db") }

    private func addSpace(id: String, name: String, isPrivate: Bool = false, sortOrder: Int = 0) throws {
        try DatabaseQueue(path: global.path).write { db in
            try db.execute(sql: "INSERT INTO spaces (id, name, icon, color, profileId, isPrivate, sortOrder) VALUES (?, ?, '💼', '#123456', ?, ?, ?)",
                           arguments: [id, name, profileId, isPrivate, sortOrder])
        }
    }

    private func addState(spaceId: String, _ state: SpaceTabState) throws {
        try DatabaseQueue(path: profileDir.appendingPathComponent("lilo.db").path).write { db in
            try db.execute(sql: "INSERT INTO spaceTabStates VALUES (?, ?, ?, ?, ?)",
                           arguments: [spaceId, state.version, SpaceTabStateCodec.codec, SpaceTabStateCodec.encode(state), Date()])
        }
    }

    private func tab(_ url: String, title: String, pinned: Bool = false, bookmarked: Bool = false) -> StoredTab {
        StoredTab(id: UUID(), url: url, title: title, faviconDataURL: nil, faviconDominantColor: nil,
                  isPinned: pinned, isBookmarked: bookmarked, isClosed: false,
                  homeURL: pinned || bookmarked ? url : nil, homeTitle: pinned || bookmarked ? title : nil,
                  homeFaviconDataURL: nil, homeFaviconDominantColor: nil, kind: .web,
                  cwd: nil, resumeCommand: nil, customTitle: nil, pageColor: nil, agentId: nil, agentSessionId: nil)
    }

    func testReadsSpacesTreesHistoryExtensionsAndFavicons() throws {
        try addSpace(id: spaceId, name: "Work")
        try addState(spaceId: spaceId, SpaceTabState(activeTabId: nil, activationHistory: [], tree: StoredSidebarTree(
            pinned: [.tab(tab("https://mail.example/", title: "Mail", pinned: true))],
            unpinned: [.tab(tab("https://news.example/", title: "News")),
                       .tab(StoredTab(id: UUID(), url: "lilo://term/1", title: "Terminal", faviconDataURL: nil, faviconDominantColor: nil,
                                      isPinned: false, isBookmarked: false, isClosed: false, homeURL: nil, homeTitle: nil,
                                      homeFaviconDataURL: nil, homeFaviconDominantColor: nil, kind: .terminal,
                                      cwd: nil, resumeCommand: nil, customTitle: nil, pageColor: nil, agentId: nil, agentSessionId: nil))],
            bookmarked: [.tab(tab("https://docs.example/", title: "Docs", bookmarked: true)),
                         .folder(StoredFolder(id: UUID(), name: "Dev", color: "#ff0000", isCollapsed: true,
                                              children: [.tab(tab("https://git.example/", title: "Git", bookmarked: true))]))]
        )))
        try DatabaseQueue(path: profileDir.appendingPathComponent("lilo.db").path).write { db in
            try db.execute(sql: "INSERT INTO history VALUES (?, 'https://news.example/', 'News', 7, ?)",
                           arguments: [UUID().uuidString, Date(timeIntervalSince1970: 1_700_000_000)])
            try db.execute(sql: "INSERT INTO favicons VALUES ('news.example', 'data:image/png;base64,AA==', '#ffffff')")
            try db.execute(sql: "INSERT INTO favicons VALUES ('other.example', 'data:image/png;base64,BB==', NULL)")
        }

        let result = LiloReader.read(profile: profile, kinds: [.bookmarks, .tabs, .history, .extensions], global: global)

        XCTAssertTrue(result.errors.isEmpty)
        let space = try XCTUnwrap(result.bundle.spaces.only)
        XCTAssertEqual(space.name, "Work")
        XCTAssertEqual(space.icon, "💼")
        XCTAssertEqual(space.pinned, [ImportedBookmark(title: "Mail", url: "https://mail.example/")])
        // A non-web tab stays behind.
        XCTAssertEqual(space.unpinned, [ImportedBookmark(title: "News", url: "https://news.example/")])
        XCTAssertEqual(space.bookmarked, [
            ImportedBookmark(title: "Docs", url: "https://docs.example/"),
            ImportedBookmark(title: "Dev", url: nil,
                             children: [ImportedBookmark(title: "Git", url: "https://git.example/")], color: "#ff0000")
        ])
        XCTAssertEqual(result.bundle.history, [ImportedVisit(url: "https://news.example/", title: "News", visitCount: 7,
                                                             lastVisitedAt: Date(timeIntervalSince1970: 1_700_000_000))])
        XCTAssertEqual(result.bundle.extensions, [ImportedExtension(id: "abcdefghijklmnopqrstuvwxyzabcde1", name: "Sample Blocker")])
        // Only hosts the import brings in get their favicon.
        XCTAssertEqual(result.bundle.favicons.map(\.host), ["news.example"])
    }

    func testTabsKindLeavesOutBookmarksAndBookmarksKindLeavesOutTabs() throws {
        try addSpace(id: spaceId, name: "Work")
        try addState(spaceId: spaceId, SpaceTabState(activeTabId: nil, activationHistory: [], tree: StoredSidebarTree(
            pinned: [.tab(tab("https://mail.example/", title: "Mail", pinned: true))],
            unpinned: [.tab(tab("https://news.example/", title: "News"))],
            bookmarked: [.tab(tab("https://docs.example/", title: "Docs", bookmarked: true))]
        )))

        let tabs = LiloReader.read(profile: profile, kinds: [.tabs], global: global).bundle.spaces.only
        XCTAssertEqual(tabs?.pinned.count, 1)
        XCTAssertEqual(tabs?.unpinned.count, 1)
        XCTAssertEqual(tabs?.bookmarked, [])

        let bookmarks = LiloReader.read(profile: profile, kinds: [.bookmarks], global: global).bundle.spaces.only
        XCTAssertEqual(bookmarks?.pinned, [])
        XCTAssertEqual(bookmarks?.unpinned, [])
        XCTAssertEqual(bookmarks?.bookmarked, [ImportedBookmark(title: "Docs", url: "https://docs.example/")])
    }

    func testPrivateSpacesAndUndecodableRowsAreSkipped() throws {
        try addSpace(id: spaceId, name: "Work")
        let privateId = UUID().uuidString
        try addSpace(id: privateId, name: "Private", isPrivate: true)
        let brokenId = UUID().uuidString
        try addSpace(id: brokenId, name: "Broken", sortOrder: 2)
        try addState(spaceId: spaceId, SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty))
        try DatabaseQueue(path: profileDir.appendingPathComponent("lilo.db").path).write { db in
            try db.execute(sql: "INSERT INTO spaceTabStates VALUES (?, ?, 'bplist', ?, ?)",
                           arguments: [privateId, SpaceTabState.currentVersion, Data("junk".utf8), Date()])
            // A row a newer Lilo wrote is skipped, never misread.
            try db.execute(sql: "INSERT INTO spaceTabStates VALUES (?, ?, 'bplist', ?, ?)",
                           arguments: [brokenId, SpaceTabState.currentVersion + 1, Data(), Date()])
        }

        let spaces = LiloReader.read(profile: profile, kinds: [.tabs], global: global).bundle.spaces
        XCTAssertEqual(spaces.map(\.name), ["Work"])
    }

    func testMissingDatabasesReportPerKindErrors() throws {
        // A space row sends the read into the profile's lilo.db, which this fixture lacks.
        try addSpace(id: spaceId, name: "Work")
        try FileManager.default.removeItem(at: profileDir.appendingPathComponent("lilo.db"))
        let result = LiloReader.read(profile: profile, kinds: [.bookmarks, .tabs, .history], global: global)
        XCTAssertNotNil(result.errors[.bookmarks])
        XCTAssertNotNil(result.errors[.tabs])
        XCTAssertNotNil(result.errors[.history])
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
