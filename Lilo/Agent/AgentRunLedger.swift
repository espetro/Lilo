import CryptoKit
import Foundation

/// The durable record of agent runs: one `start` line when a session is let in and one `end` line when
/// it leaves, appended to `runs.jsonl` beside the per-call logs by `AgentActionLog`. Live sessions are
/// memory-only, so this is what a restart can show of recent past runs, and what a cockpit lists to say
/// who worked, where and for how long. The same promise as the action log: names, ids, hosts and counts
/// only — never content, arguments, URLs or anything typed.
enum AgentRunLedger {
    /// One run as the ledger merges its `start` and `end` lines. A run with no `end` yet is live, or was
    /// cut short by a quit or a crash.
    struct Run: Equatable {
        /// The session's id: one per connection, stable for the run's life.
        let id: String
        /// The handshake's client name, and a pseudonymous hash of its name and identity.
        let client: String
        let clientKey: String
        /// ISO 8601: when the run was let in, and when its session connected.
        let started: String
        let connected: String?
        /// ISO 8601 of the `end` line; nil while the run is open.
        let ended: String?
        /// How it finished: "disconnected", "revoked", "stopped" or "adopted"; nil while open.
        let reason: String?
        let tools: Int
        let errors: Int
        let tabs: Int
        let folders: [String]
        let space: String?
        let profile: String?
        let isolated: Bool
        let conversation: String?
    }

    private static let maxRuns = 20

    /// The newest `limit` runs, most recently started first, read off the main thread's way like
    /// `AgentActionTail`: only the tail of the ledger, never a whole file.
    static func recent(in directory: URL, limit: Int = maxRuns) -> [Run] {
        var starts: [String: [String: Any]] = [:]
        var ends: [String: [String: Any]] = [:]
        // The rotated file holds the older lines: read it first so the live file's win a tie.
        for suffix in [".1.jsonl", ".jsonl"] {
            for line in AgentActionTail.tail(directory.appending(path: AgentActionLog.runsFile + suffix), maxBytes: AgentActionTail.maxBytes) {
                guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = entry["run"] as? String else { continue }
                if entry["event"] as? String == "start" { starts[id] = entry }
                if entry["event"] as? String == "end" { ends[id] = entry }
            }
        }
        return Set(starts.keys).union(ends.keys).compactMap { id in
            guard let entry = ends[id] ?? starts[id] else { return nil }
            let start = starts[id]
            let end = ends[id]
            return Run(
                id: id,
                client: start?["client"] as? String ?? "",
                clientKey: start?["clientKey"] as? String ?? "",
                started: start?["ts"] as? String ?? entry["ts"] as? String ?? "",
                connected: start?["connected"] as? String,
                ended: end?["ts"] as? String,
                reason: end?["reason"] as? String,
                tools: end?["tools"] as? Int ?? 0,
                errors: end?["errors"] as? Int ?? 0,
                tabs: end?["tabs"] as? Int ?? 0,
                folders: (end?["folders"] as? [Any])?.compactMap { $0 as? String } ?? [],
                space: end?["space"] as? String,
                profile: end?["profile"] as? String,
                isolated: end?["isolated"] as? Bool ?? false,
                conversation: start?["conversation"] as? String
            )
        }.sorted { $0.started > $1.started }.prefix(limit).map { $0 }
    }
}

extension AgentControl {
    /// The run ledger shares the action log's switch: both are the record of what agents did here.
    private var runLogging: Bool { context?.settingsStore?.get(AgentActionLog.settingKey) != "false" }

    /// A stable pseudonymous key for who is behind a session: the handshake's client name and the
    /// identity it resolved to, hashed so a signing path or team id never lands in the ledger.
    static func runClientKey(for session: AgentSession) -> String {
        let material = "\(session.clientName)\n\(session.identity)"
        return SHA256.hash(data: Data(material.utf8)).prefix(8).map { unsafe String(format: "%02x", $0) }.joined()
    }

    /// The session's `start` line, written once as it is let in.
    func recordRunStart(_ session: AgentSession) {
        guard runLogging, !session.runOpen else { return }
        session.runOpen = true
        var entry: [String: Any] = [
            "event": "start", "run": session.id.uuidString,
            "ts": Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "connected": session.connectedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "client": session.clientName, "clientKey": Self.runClientKey(for: session)
        ]
        if let conversation = session.conversationTabId?.uuidString { entry["conversation"] = conversation }
        actionLog.recordRun(entry)
    }

    /// The session's `end` line, written as it leaves, with how it finished and what the run touched.
    /// Runs before the session's folders and space go, so they can still be counted and named.
    func recordRunEnd(_ session: AgentSession, reason: String) {
        guard runLogging, session.runOpen else { return }
        session.runOpen = false
        var entry: [String: Any] = [
            "event": "end", "run": session.id.uuidString,
            "ts": Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "reason": reason, "tools": session.toolCalls, "errors": session.toolErrors,
            "isolated": session.isolatedSpaceId != nil
        ]
        var tabCount = isolatedTabs(of: session).count
        if let spaceId = agentsSpaceId(of: session) {
            entry["space"] = spaceId.uuidString
            for folderId in session.folders.values { tabCount += tabs(inFolder: folderId, spaceId: spaceId).count }
        }
        entry["tabs"] = tabCount
        if !session.folders.isEmpty { entry["folders"] = session.folders.values.map(\.uuidString).sorted() }
        if let profile = session.profileId?.uuidString ?? context?.settingsStore?.get(Self.agentsProfileKey) {
            entry["profile"] = profile
        }
        actionLog.recordRun(entry)
    }
}
