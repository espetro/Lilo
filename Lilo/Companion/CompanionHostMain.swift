import Foundation
import Darwin
import os

/// The companion extension's native-messaging host process (`lilo-companion`), speaking the
/// `protocol.ts` schema over stdin and stdout as Chrome frames them. This slice stops at the
/// wire: serving requests against the browser's real tabs is the next slice, and every tool
/// call is answered with a `not implemented yet` error until then. The Lilo app ships the
/// binary and registers it with the user's Chromium browsers through
/// `CompanionHostRegistration`, which writes the manifest template's concrete form into each
/// browser's native-messaging-hosts directory.
///
/// Chrome starts the host with one argument, the origin of the caller (`chrome-extension://<id>/`),
/// as an unspoofable identification of the extension that opened the port.
final class CompanionHostMain {
    /// Ends the run: EOF or a write failure on the pipe, or input the schema rejects.
    static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput, origin: String?) -> Never {
        Logger(liloCategory: "companion-host").log("serving \(CompanionProtocol.hostName) for \(origin ?? "an unknown origin")")
        var reader = Reader(input)
        while true {
            guard let data = reader.next() else { exit(0) }
            let message: [String: Any]
            do {
                message = try CompanionProtocol.decodeFrame(data)
            } catch {
                // The extension drops a malformed message too (nativePort.ts), so one bad frame
                // must not end a connection its later requests still need.
                Logger(liloCategory: "companion-host").error("dropping malformed message: \(error)")
                continue
            }
            if CompanionProtocol.isHello(message) {
                // The version check keeps an extension built against a future schema from
                // assuming a host that would silently drop its requests.
                let spoken = (message["protocolVersion"] as? NSNumber)?.intValue
                guard spoken == CompanionProtocol.version else {
                    Logger(liloCategory: "companion-host").error(
                        "extension speaks protocol \(spoken ?? 0), host speaks \(CompanionProtocol.version)"
                    )
                    exit(1)
                }
                continue
            }
            guard case .success(let request) = CompanionProtocol.parseRequest(message) else {
                Logger(liloCategory: "companion-host").error("dropping malformed request")
                continue
            }
            // No browser behind the wire yet: the tool implementations land with the next slice,
            // which wires this to the running Lilo's agent surface.
            let reply = CompanionProtocol.response(id: request.id, tool: request.tool, result: .failure(CompanionProtocol.RequestError(reason: "not implemented yet")))
            guard let frame = CompanionProtocol.encodeFrame(reply), writeAll(output, frame) else { exit(0) }
        }
    }

    private static func writeAll(_ handle: FileHandle, _ data: Data) -> Bool {
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Reads whole frames off the pipe: the 4-byte little-endian length, then its payload.
    private struct Reader {
        private let handle: FileHandle
        private var buffered = Data()

        init(_ handle: FileHandle) {
            self.handle = handle
        }

        mutating func next() -> Data? {
            guard let header = exactly(4) else { return nil }
            let bytes = [UInt8](header)
            let length = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
            guard length <= CompanionProtocol.maxMessageBytes, let payload = exactly(length) else { return nil }
            return header + payload
        }

        /// Exactly `count` bytes, buffered across reads; nil only at end of input or on an oversized frame.
        private mutating func exactly(_ count: Int) -> Data? {
            while buffered.count < count, let chunk = try? handle.read(upToCount: count - buffered.count), !chunk.isEmpty {
                buffered.append(chunk)
            }
            guard buffered.count >= count else { return nil }
            let frame = Data(buffered.prefix(count))
            buffered.removeSubrange(..<count)
            return frame
        }
    }
}
