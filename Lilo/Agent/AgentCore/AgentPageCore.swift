import Foundation

/// Page snapshot, change reporting and load settling over a tab's script runner, framework-free.
/// `AgentPageHost` is what an engine gives this logic: WebKit today (`WKWebViewTab` in the macOS driver),
/// WebKitGTK or WebView2 tomorrow. The page scripts (`AgentPage.js`) speak the same protocol everywhere.
/// Main-actor like everything else that touches a tab's engine.
@MainActor protocol AgentPageHost: AnyObject {
    /// The page's current URL, nil mid-navigation or for a fresh tab.
    var currentURL: URL? { get }
    /// Whether a navigation is running.
    var isLoading: Bool { get }
    /// Runs `method` from `AgentPage.js` in the page, with `arguments`; in `frame` when given.
    /// Throws when the page cannot run it (gone document, failed script).
    func page(_ method: String, _ arguments: [String: Any], in frame: (AgentPageFrame)?) async throws -> Any?
    /// The tab's live subframes, once each, by the ref prefix their script took.
    func subframes() async -> [(prefix: String, frame: AgentPageFrame)]
    /// Runs the load-quiet probe (`domQuietScript`) in the page's main world. Returns nil when the
    /// script could not run; false when the page never went quiet within `maxMs`.
    func domQuiet(quietMs: Int, maxMs: Int) async -> Bool?
    /// How long since the capture saw network activity, for pages that boot in steps.
    var lastNetworkActivity: ContinuousClock.Instant? { get }
}

/// The settle times: how long the DOM and the network must stay idle before a load counts as settled.
/// Mutable for the tests, which shorten them under the main actor.
@MainActor enum AgentSettle {
    nonisolated(unsafe) static var quiet = (dom: Duration.milliseconds(200), network: Duration.milliseconds(500))
}

/// A subframe of the page host's document, opaque to this logic: only the host resolves it.
@MainActor class AgentPageFrame {}

/// The page logic over any `AgentPageHost`: what read_page reports after an action and how a load is
/// known to have settled. Written once, every driver's agent tools share it verbatim.
@MainActor
enum AgentPageCore {
    /// The page's interactive structure in the main frame and each subframe, kept for the delta an
    /// action reports. Best effort: a page mid-navigation simply has none.
    static func snapshot(_ host: AgentPageHost) async {
        _ = try? await host.page("snapshot", [:], in: nil)
        for (_, frame) in await host.subframes() { _ = try? await host.page("snapshot", [:], in: frame) }
    }

    /// What the page's structure changed since `snapshot`, as compact +/- /~ lines, one block per frame
    /// that changed; nil when nothing did anywhere.
    static func delta(_ host: AgentPageHost) async -> String? {
        var parts: [String] = []
        if let text = try? await host.page("delta", [:], in: nil) as? String, !text.isEmpty { parts.append(text) }
        for (_, frame) in await host.subframes() {
            if let text = try? await host.page("delta", [:], in: frame) as? String, !text.isEmpty { parts.append(text) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The report an action's reply ends with: the tab's new URL when it navigated, then the structure
    /// delta, or that nothing changed.
    static func deltaReport(_ host: AgentPageHost, urlBefore: URL?) async -> String {
        var parts: [String] = []
        if host.currentURL != urlBefore, let url = host.currentURL { parts.append("The page is now at \(url.absoluteString)") }
        if let delta = await delta(host) { parts.append(delta) }
        return parts.isEmpty ? "No page changes" : parts.joined(separator: "\n")
    }

    /// Waits for the tab's load to start and settle: the DOM quiet for `settleQuiet.dom` (its own probe,
    /// within the time left), then the network quiet for `settleQuiet.network`. False past 30 s.
    static func waitForLoad(_ host: AgentPageHost, networkIdle: Bool = true) async -> Bool {
        let settleQuiet = unsafe AgentSettle.quiet
        let start = ContinuousClock.now
        let deadline = start + .seconds(30)
        // A load can take a moment to start after the request.
        while !host.isLoading, !Task.isCancelled, ContinuousClock.now - start < .milliseconds(500) { try? await Task.sleep(for: .milliseconds(20)) }
        var settleBy: ContinuousClock.Instant?
        // A cancelled sleep returns at once: without the check the loop would spin until the deadline.
        while ContinuousClock.now < deadline, !Task.isCancelled {
            // A redirect made by script starts a new load, with its own time to settle.
            if host.isLoading {
                settleBy = nil
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let limit = settleBy ?? min(ContinuousClock.now + .seconds(5), deadline)
            settleBy = limit
            guard ContinuousClock.now < limit else { return false }
            let maxMs = Int((limit - ContinuousClock.now) / .milliseconds(1))
            let asked = host.currentURL
            // The page's own timer ends the wait, but a document that goes away takes it along. Nil: the script
            // failed to run.
            let quiet = await host.domQuiet(quietMs: Int(settleQuiet.dom / .milliseconds(1)), maxMs: maxMs)
            // A document that went away is a new load, which may have finished before this resumes: that page
            // settles in turn. A script that cannot run in the page it was asked in ends the wait.
            guard let quiet else {
                if host.isLoading || host.currentURL != asked { continue }
                return true
            }
            guard quiet, !host.isLoading else { continue }
            guard networkIdle else { return true }
            // An app that boots in steps (a splash, then a config fetch from a timer) is quiet between them.
            guard let last = host.lastNetworkActivity else { return true }
            let idle = ContinuousClock.now - last
            if idle >= settleQuiet.network { return true }
            try? await Task.sleep(for: settleQuiet.network - idle)
        }
        return false
    }
}
