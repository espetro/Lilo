import Foundation
import PluginCore

/// The tools enabled plugins contribute: merged into `tools/list` with their owner, and called
/// through the plugin's sidecar under the manifest's consent tier — the gate a core tool gets,
/// never a bypass.
@MainActor
enum AgentPluginTools {
    /// `tools/list` entries of every enabled plugin. A rescan runs first so a plugin the panel
    /// has not shown yet still lists; it is a few `stat`s, and no sidecar starts for a listing.
    static func definitions(control: AgentControl) async -> [[String: Any]] {
        guard let host = control.pluginHost else { return [] }
        _ = await host.refresh()
        return host.agentToolDefinitions(reserved: AgentTools.toolNames)
    }

    /// nil when `name` is no plugin's tool, letting the caller report an unknown one.
    static func call(
        _ name: String, arguments: [String: Any], session: AgentSession, control: AgentControl
    ) async throws -> [AgentContent]? {
        guard let host = control.pluginHost, let (record, tool) = host.contributedTool(named: name) else { return nil }
        guard let plugin = await host.session(for: record.id), let manifest = record.manifest else {
            let title = record.manifest?.title ?? record.id
            throw AgentToolError("The plugin \(title) is disabled or no longer valid: enable it in Settings, then call the tool again")
        }
        if [.commit, .irreversible].contains(tool.consentTier) {
            try await control.approvePluginTool(name, pluginTitle: manifest.title, session: session)
            AgentCallSent.current?.write = true
        }
        let result: JSONValue
        do {
            result = try await plugin.request("tools/call", params: [
                "name": .string(name), "arguments": JSONValue(any: arguments)
            ])
        } catch let error as PluginSessionError {
            throw AgentToolError(message(of: error, tool: name, plugin: manifest.title))
        }
        return try content(from: result, plugin: manifest.title)
    }

    /// The plugin's tool result as agent content: an MCP-shaped `content` list maps across and
    /// `isError` becomes the call's error; anything else arrives as its JSON.
    private static func content(from result: JSONValue, plugin: String) throws -> [AgentContent] {
        guard case .object(let object) = result, case .array(let parts) = object["content"] else {
            return [.text(AgentTools.json(result.anyObject))]
        }
        let content = parts.compactMap { part -> AgentContent? in
            guard case .object(let part) = part else { return nil }
            switch part["type"] {
            case .string("text"): return part["text"]?.stringValue.map(AgentContent.text)
            case .string("image") where part["mimeType"] == .string("image/png"):
                return part["data"]?.stringValue.map(AgentContent.image)
            default: return nil
            }
        }
        if object["isError"] == .bool(true) {
            let text = content.compactMap { part -> String? in
                guard case .text(let text) = part else { return nil }
                return text
            }.joined(separator: "\n")
            throw AgentToolError(text.isEmpty ? "The plugin \(plugin) reported an error" : text)
        }
        return content.isEmpty ? [.text(AgentTools.json(result.anyObject))] : content
    }

    private static func message(of error: PluginSessionError, tool: String, plugin: String) -> String {
        switch error {
        case .deadlineExceeded:
            "The plugin \(plugin) did not answer \(tool) within \(Int(PluginSession.defaultDeadline)) s and was stopped: call the tool again if it is safe to retry"
        case .rpc(_, let message):
            "\(plugin): \(message)"
        case .protocolMismatch:
            "The plugin \(plugin) answered with a protocol Lilo does not speak: update it or Lilo"
        case .spawnFailed(let why):
            "The plugin \(plugin) could not start: \(why)"
        case .transportLost:
            "The plugin \(plugin) stopped while answering \(tool): it restarts on the next call"
        }
    }
}
