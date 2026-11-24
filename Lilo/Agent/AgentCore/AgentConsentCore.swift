import Foundation

/// The consent question state machine, framework-free: what is pending, how questions coalesce per
/// client, how answers and timeouts and withdrawals resolve, and the request dictionaries every surface
/// (the macOS drawers today, a future container's chrome tomorrow) is sent. Rendering a question and
/// drawing the user's attention are the driver's job, through the `presenter` and `attention` closures.
@MainActor
final class AgentConsentCore {
    /// How long a consent question waits for the user unless the caller says otherwise, by kind.
    static var connectionConsentTimeout: TimeInterval = 600
    static var consentTimeout: TimeInterval = 120
    static var actionConsentTimeout: TimeInterval = 45

    struct Pending {
        /// The question the client connections share, cancelled when the last one stops waiting.
        let question: Task<ConsentAnswer?, Never>
        /// How many connections still wait on it.
        var waiting: Int
    }

    struct Waiting {
        let answer: CheckedContinuation<ConsentAnswer, Never>
        /// What the surface is sent: client name, executable, action, and the request id.
        let request: [String: Any]
        /// The tab of a question about a page: only the surface holding it shows the question.
        let tabId: UUID?
    }

    /// The question asked of each client, by name and identity, and how many of its connections still wait on it.
    /// `AgentControl` owns the connection-gate questions and mutates this directly.
    var pendingConsents: [String: Pending] = [:]
    /// Questions shown in the surfaces, by request id, until the user answers.
    var pendingConsentAnswers: [String: Waiting] = [:]

    /// Presents a question on the user-facing surfaces and, when nothing is there to present on, holds
    /// it in a notification instead. Never answers by itself: the user or the timeout does.
    var present: (_ requestId: String, _ request: [String: Any]) -> Void = { _, _ in }
    /// Draws the user's attention to a question nothing on screen shows.
    var requestAttention: () -> Void = {}
    /// A question's surface went away (all windows closed): it is never answered by absence, it waits
    /// in a notification whose tap reopens a surface at it.
    var presentAsNotification: (_ requestId: String, _ request: [String: Any]) -> Void = { _, _ in }
    /// Drops a question from the surfaces without an answer: its caller gave up on it. The driver
    /// clears its drawers and notification here.
    var withdraw: (_ requestId: String) -> Void = { _ in }

    /// Asks the user the question `request` describes for client `key` (its name and identity, so two
    /// connections of one client share it). Answered with `.allowed`/`.denied` from a surface, `.expired`
    /// past `timeout` or on withdrawal, `.unavailable` when nothing could present it (`canPresent` says
    /// the surfaces are gone and only the notification holds the question).
    func ask(_ key: String, request: [String: Any], tabId: UUID?, timeout: TimeInterval, canPresent: Bool = true) async -> ConsentAnswer {
        let requestId = UUID().uuidString
        var shown = request
        shown["requestId"] = requestId
        let question: Task<ConsentAnswer?, Never> = pendingConsents[key]?.question ?? Task { @MainActor in
            let answer = await self.waitForAnswer(requestId: requestId, shown: shown, tabId: tabId, timeout: timeout, notify: !canPresent)
            self.pendingConsents[key] = nil
            return answer
        }
        pendingConsents[key] = Pending(question: question, waiting: (pendingConsents[key]?.waiting ?? 0) + 1)
        // Cancellation does not reach into `question`, so the caller's own cancellation withdraws the
        // question here: a tool call the client gave up on leaves nothing waiting on the surfaces.
        let answer = await withTaskCancellationHandler {
            await question.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.expire(requestId) }
        }
        if let pending = pendingConsents[key], pending.question == question {
            pendingConsents[key]?.waiting -= 1
            if pending.waiting == 1 { question.cancel() }
        }
        return answer ?? .expired
    }

    /// The one connection that holds the question asks it; the others join and get the same answer.
    /// `notify` holds the question in a notification (nothing on screen could present it), whose tap
    /// reopens a surface; it is never answered by absence.
    private func waitForAnswer(requestId: String, shown: [String: Any], tabId: UUID?, timeout: TimeInterval, notify: Bool) async -> ConsentAnswer? {
        if notify { presentAsNotification(requestId, shown) } else {
            present(requestId, shown)
            requestAttention()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            Task { @MainActor [weak self] in self?.expire(requestId) }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pendingConsentAnswers[requestId] = Waiting(answer: $0, request: shown, tabId: tabId) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.expire(requestId) }
        }
    }

    /// A question nobody answers any more: it leaves the surfaces, and its caller resolves as unanswered.
    private func expire(_ requestId: String) {
        guard pendingConsentAnswers[requestId] != nil else { return }
        answer(requestId, granted: nil, allowedSites: [])
        withdraw(requestId)
    }

    /// The user's answer from a surface, nil when nobody answered: the others drop the same question.
    /// Returns the site to always allow from now on, nil when the answer adds none.
    @discardableResult
    func answer(_ requestId: String, granted: Bool?, alwaysAllowSite: String? = nil, allowedSites: [String]) -> [String]? {
        guard let waiting = pendingConsentAnswers.removeValue(forKey: requestId) else { return nil }
        let saving = AgentConsentRules.savingAlwaysAllowSite(granted, alwaysAllowSite: alwaysAllowSite, sites: allowedSites)
        waiting.answer.resume(returning: granted.map { $0 ? .allowed : .denied } ?? .expired)
        return saving
    }

    /// A question still waiting when its surface just loaded is shown again: the new surface never got it.
    func resendPending(to surfaces: [(holdsTab: (UUID) -> Bool, show: ([String: Any]) -> Void)]) {
        for waiting in pendingConsentAnswers.values {
            for surface in surfaces where waiting.tabId.map(surface.holdsTab) ?? true {
                surface.show(waiting.request)
            }
        }
    }
}
