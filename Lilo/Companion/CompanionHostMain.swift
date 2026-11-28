import Foundation
import Darwin
import os

/// The companion extension's native-messaging host process (`lilo-companion`). Chrome starts it
/// with the caller's origin as its only argument and speaks native messaging over its standard
/// input and output. The host answers nothing itself: it is a byte pipe between that stdio and
/// the unix socket a Lilo peer listens on (the app, or the headless container of the Linux
/// install path), so the validation of the `protocol.ts` schema happens exactly once on each
/// side that speaks it — the extension in `nativePort.ts`, the peer in its tool surface — and
/// never here.
///
/// The socket path is `LILO_COMPANION_SOCK` when set (tests, the container), else
/// `~/Library/Application Support/Lilo/companion.sock`. When no peer is listening the host exits
/// at once: the extension's port disconnects and it retries on its own backoff, which is how a
/// not-yet-running Lilo and a browser restart converge without any state on this side.
final class CompanionHostMain {
    static func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput, origin: String?) -> Never {
        let logger = Logger(liloCategory: "companion-host")
        guard let path = socketPath(), let fd = connectUnixSocket(path) else {
            logger.log("no companion peer listening, leaving \(CompanionProtocol.hostName) dormant")
            exit(1)
        }
        logger.log("piping \(CompanionProtocol.hostName) for \(origin ?? "an unknown origin") to \(path)")
        // stdin to the socket on a worker, the socket to stdout here. stdin reaching EOF means the
        // browser closed the port, so the host exits rather than lingering on a half-closed socket.
        let writeEnd = dup(fileno(stdout))
        Thread.detachNewThread {
            copyBytes(from: fileno(stdin), to: fd)
            shutdown(fd, SHUT_WR)
            exit(0)
        }
        copyBytes(from: fd, to: writeEnd)
        exit(0)
    }

    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String? {
        if let override = environment["LILO_COMPANION_SOCK"], !override.isEmpty { return override }
        return "\(home)/Library/Application Support/Lilo/companion.sock"
    }

    private static func connectUnixSocket(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= capacity else { close(fd); return nil }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strlcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, capacity + 1) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    /// Blocks copying `from` into `to` until the read end closes or either side fails.
    private static func copyBytes(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            var written = 0
            while written < count {
                let step = buffer.withUnsafeBytes { write(destination, $0.baseAddress?.advanced(by: written), count - written) }
                guard step > 0 else { return }
                written += step
            }
        }
    }
}
