import XCTest
@testable import Lilo

/// The companion host's wire: Chrome's framing (a UInt32 little-endian byte count then UTF-8
/// JSON), the `protocol.ts` schema the host mirrors, and the manifest the browser reads to find
/// the host. The shared contract cases in `companion-extension/src/protocol.fixtures.json` run
/// here and against the TypeScript validator, so the two cannot drift.
final class CompanionHostTests: XCTestCase {
    /// The contract cases, each either accepted or rejected with the exact message `protocol.ts` returns.
    private func contractCases() throws -> [(name: String, message: [String: Any], error: String?)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("companion-extension/src/protocol.fixtures.json")
        let fixtures = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(fixtures["cases"] as? [[String: Any]])
        return try cases.map { entry in
            (
                name: try XCTUnwrap(entry["name"] as? String),
                message: try XCTUnwrap(entry["message"] as? [String: Any]),
                error: entry["error"] as? String
            )
        }
    }

    // MARK: Framing

    func testAFrameIsALittleEndianLengthThenItsJSON() throws {
        let message: [String: Any] = ["id": "r1", "ok": true]
        let frame = try XCTUnwrap(CompanionProtocol.encodeFrame(message))
        let length = frame.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        XCTAssertEqual(length, frame.count - 4)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: frame.dropFirst(4)) as? [String: Any])
        XCTAssertEqual(decoded["id"] as? String, "r1")
        XCTAssertEqual(decoded["ok"] as? Bool, true)
    }

    func testAFrameRoundTrips() throws {
        let message: [String: Any] = ["id": "r2", "tool": "tabs.open", "params": ["url": "https://example.com/", "background": true]]
        let frame = try XCTUnwrap(CompanionProtocol.encodeFrame(message))
        XCTAssertEqual(try CompanionProtocol.decodeFrame(frame) as NSDictionary, message as NSDictionary)
    }

    func testATruncatedOrOversizedFrameIsRejected() {
        XCTAssertThrowsError(try CompanionProtocol.decodeFrame(Data([1, 2])))
        // A length header that does not match the payload: the frame is cut short.
        XCTAssertThrowsError(try CompanionProtocol.decodeFrame(Data([10, 0, 0, 0, 1, 2])))
    }

    func testAMessageThatIsNotJSONOrNotAnObjectIsRejected() {
        var notJSON = Data([2, 0, 0, 0])
        notJSON.append(contentsOf: Array("no".utf8))
        XCTAssertThrowsError(try CompanionProtocol.decodeFrame(notJSON))
        var notAnObject = Data([2, 0, 0, 0])
        notAnObject.append(contentsOf: Array("[]".utf8))
        XCTAssertThrowsError(try CompanionProtocol.decodeFrame(notAnObject))
    }

    func testAMessageThatIsNotValidJSONIsNotEncoded() {
        XCTAssertNil(CompanionProtocol.encodeFrame(["value": Double.nan]))
    }

    // MARK: Schema

    func testTheHostAgreesWithTheTypeScriptSchemaOnEveryContractCase() throws {
        for contract in try contractCases() {
            switch CompanionProtocol.parseRequest(contract.message) {
            case .success:
                XCTAssertNil(contract.error, "\(contract.name): the host accepted what the schema rejects")
            case .failure(let error):
                XCTAssertEqual(error.reason, contract.error, "\(contract.name): the host and the schema disagree")
            }
        }
    }

    func testTheHostAcceptsARequestTheSchemaAccepts() throws {
        guard case .success(let request) = CompanionProtocol.parseRequest([
            "id": "r1", "tool": "snapshot", "params": ["tabId": 3, "maxChars": 100]
        ]) else { return XCTFail("a valid snapshot request must be accepted") }
        XCTAssertEqual(request.id, "r1")
        XCTAssertEqual(request.tool, "snapshot")
        XCTAssertEqual(request.params["tabId"] as? Double, 3)
    }

    func testTheHelloIsRecognizedAndCarriesTheProtocolVersion() {
        XCTAssertTrue(CompanionProtocol.isHello(["type": "hello", "protocolVersion": 1, "peer": "com.getlilo.lilo.companion"]))
        XCTAssertFalse(CompanionProtocol.isHello(["id": "r1", "tool": "tabs.list", "params": [:]]))
        XCTAssertEqual(CompanionProtocol.version, 1)
    }

    func testASuccessResponseCarriesTheIdTheToolAndTheResult() {
        let reply = CompanionProtocol.response(id: "r1", tool: "tabs.open", result: .success(["tabId": 9]))
        XCTAssertEqual(reply["id"] as? String, "r1")
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["tool"] as? String, "tabs.open")
        let result = try? XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result?["tool"] as? String, "tabs.open")
        XCTAssertEqual((result?["result"] as? [String: Any])?["tabId"] as? Double, 9)
    }

    func testAFailureResponseCarriesTheIdTheToolAndTheMessage() {
        let reply = CompanionProtocol.response(id: "r2", tool: "snapshot", result: .failure(CompanionProtocol.RequestError(reason: "no such tab")))
        XCTAssertEqual(reply["id"] as? String, "r2")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["tool"] as? String, "snapshot")
        XCTAssertEqual(reply["error"] as? String, "no such tab")
        XCTAssertNil(reply["result"])
    }

    // MARK: Manifest

    func testTheManifestTemplateNamesTheHostAndTheExtensionItAllows() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lilo/Resources/companion-host/com.getlilo.lilo.companion.json.in")
        let template = try String(contentsOf: url, encoding: .utf8)
        // Chromium reads JSON: the template must parse once its placeholders are filled.
        XCTAssertTrue(template.contains("\"name\": \"\(CompanionProtocol.hostName)\""))
        XCTAssertTrue(template.contains("\"type\": \"stdio\""))
        XCTAssertTrue(template.contains("chrome-extension://@EXTENSION_ID@/"))
        XCTAssertTrue(template.contains("\"path\": \"@HOST_PATH@\""))
    }

    func testTheFilledManifestIsTheJSONChromiumReads() throws {
        let filled = try CompanionHostRegistration.manifest(
            template: "{\"name\": \"com.getlilo.lilo.companion\", \"path\": \"@HOST_PATH@\", \"type\": \"stdio\", \"allowed_origins\": [\"chrome-extension://@EXTENSION_ID@/\"]}",
            hostPath: "/Applications/Lilo.app/Contents/MacOS/lilo-companion"
        )
        let object = try XCTUnwrap(filled as? [String: Any])
        XCTAssertEqual(object["name"] as? String, CompanionProtocol.hostName)
        XCTAssertEqual(object["path"] as? String, "/Applications/Lilo.app/Contents/MacOS/lilo-companion")
        XCTAssertEqual(object["type"] as? String, "stdio")
        XCTAssertEqual(object["allowed_origins"] as? [String], ["chrome-extension://\(CompanionHostRegistration.extensionId)/"])
    }

    func testTheExtensionIdIsTheOneTheExtensionPins() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("companion-extension/manifest.json")
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(manifest["key"] as? String, "the extension pins its key, so its id survives a reload")
        XCTAssertEqual(CompanionHostRegistration.extensionId.count, 32)
        XCTAssertTrue(CompanionHostRegistration.extensionId.allSatisfy { $0.isLetter && $0.isLowercase })
    }
}

/// The real `lilo-companion` binary, driven over stdin and stdout as a browser drives it: the
/// wire end to end, not just the schema in process. Runs no window and takes no keyboard focus.
@MainActor
final class CompanionHostProcessTests: XCTestCase {
    private func launch() throws -> (Process, FileHandle, FileHandle) {
        let executable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/lilo-companion")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("lilo-companion ships only in the Xcode-built app")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["chrome-extension://\(CompanionHostRegistration.extensionId)/"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        return (process, input.fileHandleForWriting, output.fileHandleForReading)
    }

    private func send(_ handle: FileHandle, _ message: [String: Any]) throws {
        try handle.write(contentsOf: XCTUnwrap(CompanionProtocol.encodeFrame(message)))
    }

    /// The next framed message the host writes, read off the main thread so the host keeps running.
    private func receive(_ handle: FileHandle) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                while data.count < 4, let chunk = try? handle.read(upToCount: 4 - data.count), !chunk.isEmpty { data.append(chunk) }
                guard data.count == 4 else { return continuation.resume(returning: nil) }
                let length = data.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
                var payload = Data()
                while payload.count < length, let chunk = try? handle.read(upToCount: length - payload.count), !chunk.isEmpty { payload.append(chunk) }
                continuation.resume(returning: (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])
            }
        }
    }

    func testTheHostServesTheSchemaEndToEnd() async throws {
        let (process, input, output) = try launch()
        defer { process.terminate() }

        try send(input, ["type": "hello", "protocolVersion": CompanionProtocol.version, "peer": CompanionProtocol.hostName])
        try send(input, ["id": "e1", "tool": "tabs.list", "params": [:]])
        guard let reply = await receive(output) else { return XCTFail("the host answered nothing") }
        XCTAssertEqual(reply["id"] as? String, "e1")
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["tool"] as? String, "tabs.list")
        XCTAssertEqual(reply["error"] as? String, "not implemented yet")

        // A malformed request is dropped, and the next one is still served: the connection survives it.
        try send(input, ["id": "e2", "tool": "cookies.read", "params": [:]])
        try send(input, ["id": "e3", "tool": "snapshot", "params": ["tabId": 1]])
        guard let next = await receive(output) else { return XCTFail("the host stopped after a malformed request") }
        XCTAssertEqual(next["id"] as? String, "e3", "the malformed request is dropped without ending the connection")

        try input.close()
        // The host reads to EOF and exits on its own, as a browser closing the port leaves it.
        let exited = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        XCTAssertEqual(exited, 0, "the browser closing the port ends the host")
    }
}
