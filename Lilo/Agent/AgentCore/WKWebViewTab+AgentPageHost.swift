import WebKit

/// The macOS driver's `AgentPageHost`: a tab's web view speaking what `AgentPageCore` consumes, so the
/// snapshot, delta and settling logic stays framework-free and shared with future drivers. The tab has
/// no capture of its own; the network-quiet half of settling is the macOS driver's extra condition in
/// `AgentTools.waitForLoad`, and here reports no network activity at all.
extension WKWebViewTab: AgentPageHost {
    var agentPageHost: AgentPageHost { self }

    func page(_ method: String, _ arguments: [String: Any], in frame: (AgentPageFrame)?) async throws -> Any? {
        try await AgentTools.page(self, method, arguments, in: (frame as? UnsafeFrame)?.frame)
    }

    func subframes() async -> [(prefix: String, frame: AgentPageFrame)] {
        let frames = await AgentTools.subframes(of: self)
        return frames.map { (prefix: $0.prefix, frame: UnsafeFrame(frame: $0.frame)) }
    }

    /// Wraps a `WKFrameInfo` as the opaque `AgentPageFrame`, which `page` unwraps back.
    private final class UnsafeFrame: AgentPageFrame {
        let frame: WKFrameInfo
        init(frame: WKFrameInfo) { self.frame = frame }
    }

    /// The load-quiet probe of `AgentTools.domQuietScript`, with the timeout that keeps a page that
    /// never paints from hanging the wait.
    func domQuiet(quietMs: Int, maxMs: Int) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            var answered = false
            let answer = { (value: Bool?) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: value)
            }
            wkWebView.callAsyncJavaScript(
                AgentTools.domQuietScript, arguments: ["quietMs": quietMs, "maxMs": maxMs], in: nil, in: AgentInput.world
            ) { answer((try? $0.get()) as? Bool) }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(maxMs + 100)) { answer(false) }
        }
    }

    var lastNetworkActivity: ContinuousClock.Instant? { nil }
}
