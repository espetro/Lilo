import Foundation

/// The companion extension's wire schema, mirrored from `companion-extension/src/protocol.ts`
/// (protocol version 1). The extension exposes a Chromium browser's tabs and pages to the Lilo
/// agent; its native-messaging peer speaks this schema over Chrome's native messaging, which
/// frames each side's messages as a UInt32 little-endian byte count followed by UTF-8 JSON.

enum CompanionProtocol {
    static let version = 1
    /// The host name the extension connects to, matching `DEFAULT_PEER_NAME` in `nativePort.ts`
    /// and the file name of the native-messaging-hosts manifest in `Contents/Resources`.
    static let hostName = "com.getlilo.lilo.companion"
    /// Chrome's limit for a message the host sends; a larger snapshot is truncated by the extension.
    static let maxMessageBytes = 64 * 1024 * 1024

    enum MessageError: Error, CustomStringConvertible {
        case truncated, tooLarge(Int), notJSON, notAnObject

        var description: String {
            switch self {
            case .truncated: "native messaging message is truncated"
            case .tooLarge(let bytes): "native messaging message of \(bytes) bytes is over the limit"
            case .notJSON: "native messaging message is not JSON"
            case .notAnObject: "native messaging message is not an object"
            }
        }
    }

    /// Why `parseRequest` rejects a message: the string `protocol.ts` would return.
    struct RequestError: Error {
        let reason: String
    }

    /// Decodes one framed message: a UInt32 little-endian length, then that many UTF-8 JSON bytes.
    static func decodeFrame(_ data: Data) throws -> [String: Any] {
        guard data.count >= 4 else { throw MessageError.truncated }
        let bytes = [UInt8](data.prefix(4))
        let length = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        let payload = data.dropFirst(4)
        guard length == payload.count, length <= maxMessageBytes else { throw MessageError.tooLarge(length) }
        guard let message = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw JSONSerialization.isValidJSONObject(payload) ? MessageError.notAnObject : MessageError.notJSON
        }
        return message
    }

    /// Encodes a framed message, or nil when it is not valid JSON.
    static func encodeFrame(_ message: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(message), let payload = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        // The length header, little-endian, as Chrome frames it.
        let count = UInt32(payload.count)
        var frame = Data([UInt8(count & 0xff), UInt8((count >> 8) & 0xff), UInt8((count >> 16) & 0xff), UInt8((count >> 24) & 0xff)])
        frame.append(payload)
        return frame
    }

    /// The hello the extension sends once the port is open; the host answers nothing and serves requests.
    static func isHello(_ message: [String: Any]) -> Bool {
        message["type"] as? String == "hello"
    }

    // MARK: Requests

    /// The tools and their parameter names and types, as `protocol.ts` validates them. Types:
    /// s string, n finite number, b boolean, as string array, aa JSON array.
    private static let tools: [String: [(name: String, type: String, required: Bool)]] = [
        "tabs.list": [("urlPrefixes", "as", false)],
        "tabs.open": [("url", "s", true), ("background", "b", false)],
        "snapshot": [("tabId", "n", true), ("maxChars", "n", false)],
        "scripting.execute": [("tabId", "n", true), ("funcSource", "s", true), ("args", "aa", false)]
    ]

    /// What JSONSerialization handed over for `value`, as the JSON type `protocol.ts` checks:
    /// numbers and booleans both arrive as NSNumber, and `as?` blurs them (`1 as? Bool` is
    /// true, an integer is not a Double).
    private static func jsonType(of value: Any) -> String? {
        guard let number = value as? NSNumber else {
            switch value {
            case is String: return "string"
            case is [Any]: return "array"
            case is [String: Any]: return "object"
            default: return nil
            }
        }
        // CFBooleanRef-backed NSNumbers are JSON's true and false; anything else is a number.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
        return number.doubleValue.isFinite ? "number" : nil
    }

    /// A request the extension sent, or the error string the schema rejects it with, as
    /// `parseRequest` in `protocol.ts` builds them: host and extension must agree, so a
    /// malformed request is dropped by both rather than answered with a guessed shape.
    static func parseRequest(_ message: [String: Any]) -> Result<(id: String, tool: String, params: [String: Any]), RequestError> {
        guard let id = message["id"] as? String, !id.isEmpty else {
            return .failure(RequestError(reason: "request.id must be a non-empty string"))
        }
        guard let tool = message["tool"] as? String, tools[tool] != nil else {
            return .failure(RequestError(reason: "unknown tool: \(message["tool"] as? String ?? String(describing: message["tool"]))"))
        }
        guard let params = message["params"] as? [String: Any] else {
            return .failure(RequestError(reason: "request.params must be an object"))
        }
        for (name, type, required) in tools[tool] ?? [] {
            guard let value = params[name] else {
                guard !required else { return .failure(RequestError(reason: "\(tool) requires params.\(name)")) }
                continue
            }
            switch type {
            case "s":
                guard jsonType(of: value) == "string" else { return .failure(RequestError(reason: "params.\(name) must be string")) }
            case "n":
                guard jsonType(of: value) == "number" else { return .failure(RequestError(reason: "params.\(name) must be number")) }
            case "b":
                guard jsonType(of: value) == "boolean" else { return .failure(RequestError(reason: "params.\(name) must be boolean")) }
            case "as":
                guard let list = value as? [Any], list.allSatisfy({ jsonType(of: $0) == "string" }) else {
                    return .failure(RequestError(reason: "params.\(name) must be string[]"))
                }
            default:
                guard jsonType(of: value) == "array" else { return .failure(RequestError(reason: "params.\(name) must be an array")) }
            }
        }
        return .success((id, tool, params))
    }

    /// What the host answered, ready for `encodeFrame`: the request id and tool echoed, and
    /// the result under the tool key the extension reads, or the error message. The result is
    /// the `CompanionResult` of the schema (`{tool: "tabs.open", tabId: 9}`), which carries the
    /// tool's own name: `successResponse` in `protocol.ts` wraps it as it is.
    static func response(id: String, tool: String, result: Result<[String: Any], RequestError>) -> [String: Any] {
        switch result {
        case .success(let value):
            ["id": id, "ok": true, "tool": tool, "result": value]
        case .failure(let error):
            ["id": id, "ok": false, "tool": tool, "error": error.reason]
        }
    }
}
