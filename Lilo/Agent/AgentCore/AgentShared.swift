import Foundation

/// The agent surface's shared vocabulary and the pure rules around it, framework-free: a future engine
/// driver (WebKitGTK, WebView2) implements what these speak without touching them.

/// How the user's answer to a consent question ended: allowed, declined, or no answer at all (the question
/// expired unanswered, or nothing could ask). `AgentToolError.consent` carries the raw value to the agent.
enum ConsentAnswer: String {
    case allowed, denied, expired, unavailable
}

enum AgentContent {
    case text(String)
    /// A PNG, base64 encoded off the main thread.
    case image(String)

    var json: [String: Any] {
        switch self {
        case .text(let text): ["type": "text", "text": text]
        case .image(let base64): ["type": "image", "data": base64, "mimeType": "image/png"]
        }
    }
}

struct AgentToolError: LocalizedError {
    let message: String
    /// Stable and machine-readable, sent as `_meta["lilo/errorCode"]`: "needs_user" when only the user can unblock the call.
    let code: String?
    /// The consent answer behind a `needs_user` refusal, sent as `_meta["lilo/consent"]`.
    let consent: ConsentAnswer?
    init(_ message: String, code: String? = nil, consent: ConsentAnswer? = nil) {
        self.message = message
        self.code = code
        self.consent = consent
    }
    var errorDescription: String? { message }
}

/// Handshake names as people know them: "claude-code" is Claude Code, "gemini-cli-mcp-client" Gemini CLI.
enum AgentClientNaming {
    static func displayName(_ clientName: String) -> String {
        let name = clientName.lowercased()
        // The Claude app's agent mode names itself after the MCP server it connects to.
        if name.hasPrefix("local-agent-mode-") { return "Claude" }
        if let known = [
            "claude-code": "Claude Code", "claude-ai": "Claude", "codex": "Codex", "codex-mcp-client": "Codex",
            "cursor": "Cursor", "cursor-vscode": "Cursor"
        ][name] { return known }
        // A name the agent styled itself ("Test Agent", "Goose") stays as it is.
        guard name == clientName, name.contains(where: { "-_.".contains($0) }) else { return clientName }
        let words = name.split(whereSeparator: { "-_. ".contains($0) }).filter { $0 != "mcp" && $0 != "client" }
        guard !words.isEmpty else { return clientName }
        return words.map { ["ai": "AI", "cli": "CLI", "ide": "IDE", "vscode": "VS Code"][$0] ?? $0.capitalized }.joined(separator: " ")
    }
}

/// How one agent acts on pages, kept per app (its `AgentClientConfig.Client` id, or the agent's own name when no
/// app is known) beside the global setting and site list. It only ever removes questions about ordinary actions:
/// a sensitive one (signing in, paying, buying, deleting, publishing, sending data to another site) asks every agent.
struct AgentClientPermission: Codable, Equatable {
    enum Act: String, Codable { case ask, sites, always }

    var act: Act = .ask
    /// Where `.sites` acts unasked, their subdomains included.
    var sites: [String] = []

    init(act: Act = .ask, sites: [String] = []) {
        self.act = act
        self.sites = sites
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        act = (try? values.decodeIfPresent(Act.self, forKey: .act)) ?? .ask
        sites = (try? values.decodeIfPresent([String].self, forKey: .sites)) ?? []
    }

    var isDefault: Bool { act == .ask && sites.isEmpty }

    static let settingKey = "agentClientPermissions"

    /// Whether the user is asked before an action on `site`. The global setting and site list decide first; then a
    /// sensitive action always asks; then the agent's own choice.
    static func asks(sensitive: Bool, site: String, globalAsks: Bool, globalSites: [String], client: AgentClientPermission?) -> Bool {
        guard globalAsks, !covers(globalSites, site) else { return false }
        guard !sensitive, let client else { return true }
        switch client.act {
        case .ask: return true
        case .sites: return !covers(client.sites, site)
        case .always: return false
        }
    }

    /// Whether `site` is one of `sites` or a subdomain of one.
    static func covers(_ sites: [String], _ site: String) -> Bool {
        sites.contains { site == $0 || site.hasSuffix("." + $0) }
    }

    static func decode(_ json: String?) -> [String: AgentClientPermission] {
        json.flatMap { try? JSONDecoder().decode([String: AgentClientPermission].self, from: Data($0.utf8)) } ?? [:]
    }

    /// Entries still at the default are dropped: an absent agent follows the global setting.
    static func encode(_ permissions: [String: AgentClientPermission]) -> String {
        let kept = permissions.filter { !$0.value.isDefault }
        return (try? JSONEncoder().encode(kept)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}

/// The agent consent decision table's storage and errors: what is kept in settings, and the `needs_user`
/// errors an answer produces. The asking itself is the macOS driver's (drawers, notifications); a future
/// driver renders the same request in its own surface and answers through the same store.
@MainActor
enum AgentConsentRules {
    static let asksBeforeActionsKey = "agentAskBeforeActions"
    static let alwaysAllowedSitesKey = "agentAlwaysAllowedSites"

    /// Sites where the user always lets agents send, pay, delete or publish, their subdomains included.
    static func alwaysAllowedSites(from store: SettingsStore?) -> [String] {
        store?.get(Self.alwaysAllowedSitesKey)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    /// How each agent acts on pages, by app id, or by agent name when no app is known.
    static func clientPermissions(from store: SettingsStore?) -> [String: AgentClientPermission] {
        AgentClientPermission.decode(store?.get(AgentClientPermission.settingKey))
    }

    static func setClientPermission(_ key: String, _ permission: AgentClientPermission, store: SettingsStore?) {
        var all = clientPermissions(from: store)
        all[key] = permission
        store?.set(AgentClientPermission.settingKey, value: AgentClientPermission.encode(all))
    }

    /// The site list to persist when the user's answer allows a site from now on, nil when the answer
    /// adds nothing (`granted` is not a plain allow, the site is empty or already listed).
    static func savingAlwaysAllowSite(_ granted: Bool?, alwaysAllowSite: String?, sites: [String]) -> [String]? {
        guard granted == true, let site = alwaysAllowSite, !site.isEmpty, !sites.contains(site) else { return nil }
        return sites + [site]
    }

    /// `needs_user` for a question that expired unanswered: withdrawn, and the agent may ask once more.
    static func expiredConsentError(timeout: TimeInterval) -> AgentToolError {
        AgentToolError("The user did not answer within \(Int(timeout)) s, so the question was withdrawn: call the tool again once to ask again; if it expires again, stop and tell the user what is waiting", code: "needs_user", consent: .expired)
    }

    /// `needs_user` for a question nothing on screen could show.
    static var unavailableConsentError: AgentToolError {
        AgentToolError("Lilo has no window to ask the user in: ask them to open one, then call again", code: "needs_user", consent: .unavailable)
    }
}
