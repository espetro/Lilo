import Foundation
import OSLog

/// The plain release feed an unsigned build watches (`LILOBetaUpdateFeedURL` in Info.plist), which
/// Sparkle cannot serve: it signs appcasts, and an ad-hoc signed app has no Sparkle key. The feed
/// lists JSON releases; the checker compares the newest release's tag with the one this build
/// installed itself from and reports a newer one for the chrome to show. It never downloads or
/// replaces anything - the release page is the update path (docs/FORK-BETA.md).
@MainActor
final class BetaUpdateChecker {
    static let installedTagKey = "installedBetaTag"
    static let feedURLOverrideKey = "betaUpdateFeedURLOverride"
    private static let logger = Logger(liloCategory: "beta-update")

    private let compiledFeedURL: String?
    private let session: URLSession
    /// The channel picked in Settings ("stable" or "beta"); the check stays idle off beta.
    var updateChannel = "beta"
    /// Set once a check answers, so the settings row shows something honest while none ran yet.
    private(set) var lastCheck: Date?
    /// The newer release found: its tag and the release's HTML page, nil while this build is the newest.
    private(set) var available: (tag: String, url: String)?
    /// The launch check runs once; Settings' row re-checks on demand.
    private var hasChecked = false

    init(feedURL: String? = Bundle.main.object(forInfoDictionaryKey: "LILOBetaUpdateFeedURL") as? String,
         session: URLSession = .shared) {
        self.compiledFeedURL = feedURL
        self.session = session
    }

    /// The feed the check reads: a URL the Settings field stored wins over the one compiled into the
    /// build, so another fork points its beta at its own releases without rebuilding.
    var feedURL: URL? {
        let raw = UserDefaults.standard.string(forKey: Self.feedURLOverrideKey) ?? compiledFeedURL
        return raw.flatMap { URL(string: $0) }.flatMap { $0.host != nil && $0.scheme != nil ? $0 : nil }
    }

    /// The URL the Settings field shows as the override, nil while the build's own feed applies.
    var feedURLOverride: String? { UserDefaults.standard.string(forKey: Self.feedURLOverrideKey) }

    /// False in builds without a feed URL, whose rows stay honest about never checking.
    var isConfigured: Bool { feedURL != nil }

    /// An empty URL removes the override and the compiled-in feed applies again.
    func setFeedURLOverride(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: Self.feedURLOverrideKey) } else {
            UserDefaults.standard.set(trimmed, forKey: Self.feedURLOverrideKey)
        }
    }

    /// The tag this build was published as, stamped at build time. A local build has none and keeps the
    /// tag the newest release had the first time it ran, so a check on an older build keeps finding the
    /// newer one even after GitHub prunes it from the feed.
    var installedTag: String {
        get {
            let stamped = Bundle.main.object(forInfoDictionaryKey: "LILOBetaTag") as? String ?? ""
            return stamped.isEmpty ? UserDefaults.standard.string(forKey: Self.installedTagKey) ?? "" : stamped
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.installedTagKey) }
    }

    /// One check on launch, never scheduled: the release page, not an installer, is the update path.
    func startSharedCheck(notify: (@MainActor () -> Void)? = nil) {
        guard isConfigured, !ProcessInfo.isRunningUnderXCTest, !hasChecked else { return }
        hasChecked = true
        Task { @MainActor in
            await check()
            notify?()
        }
    }

    func check() async {
        guard updateChannel == "beta", let feedURL else { return }
        lastCheck = Date()
        do {
            let (data, response) = try await session.data(from: feedURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let newest = Self.newestTag(in: data).map { (tag: $0, url: Self.releaseURL(in: data, tag: $0)) }
            guard let newest else { return }
            if installedTag.isEmpty { installedTag = newest.tag }
            guard Self.isNewer(newest.tag, than: installedTag) else { available = nil; return }
            available = newest
        } catch {
            Self.logger.error("feed check failed: \(error.localizedDescription)")
        }
    }

    /// The largest `beta-N` number in the feed's JSON array, so "newest" survives a re-numbering tag
    /// or a release published out of order.
    nonisolated static func newestTag(in data: Data) -> String? {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return releases
            .compactMap { $0["tag_name"] as? String }
            .compactMap { tag -> (number: Int, tag: String)? in
                guard let number = tagNumber(tag) else { return nil }
                return (number, tag)
            }
            .max { $0.number < $1.number }?.tag
    }

    /// The matching release's `html_url`, empty when the entry has none.
    nonisolated static func releaseURL(in data: Data, tag: String) -> String {
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return "" }
        return releases.first { $0["tag_name"] as? String == tag }.flatMap { $0["html_url"] as? String } ?? ""
    }

    nonisolated static func tagNumber(_ tag: String) -> Int? {
        guard tag.hasPrefix("beta-"), let number = Int(tag.dropFirst("beta-".count)) else { return nil }
        return number
    }

    nonisolated static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let candidate = tagNumber(candidate), let installed = tagNumber(installed) else { return false }
        return candidate > installed
    }
}
