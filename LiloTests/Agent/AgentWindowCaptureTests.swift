import AppKit
import XCTest
@testable import Lilo

@MainActor
final class AgentWindowCaptureTests: AgentToolTestCase {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testTheToolRendersTheWindowAtTheRequestedSize() async throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("window-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        let reply = await client.callTool("window_capture", ["path": png.path, "width": 640, "height": 480])
        XCTAssertFalse(reply.isError, reply.text)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)))
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThanOrEqual(image.pixelsHigh * 640, image.pixelsWide * 480, "the frame, titlebar included, is at least as tall as the content")
    }

    func testTheToolRefusesARelativePath() async {
        let reply = await client.callTool("window_capture", ["path": "shot.png"])
        XCTAssertTrue(reply.isError)
    }

    /// A Release build must hold no trace of the tool: its file is one `#if DEBUG` block and every other mention
    /// of it sits inside one.
    func testTheToolIsCompiledOutOfRelease() throws {
        let sources = Self.repository.appendingPathComponent("Lilo")
        let file = sources.appendingPathComponent("Agent/AgentWindowCapture.swift")
        let own = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(own.hasPrefix("#if DEBUG"), "the file starts its DEBUG block")
        XCTAssertTrue(own.hasSuffix("#endif"), "the file ends its DEBUG block")
        XCTAssertEqual(own.components(separatedBy: "\n#if ").count - 1, 0, "no nested conditional that could close the block early")

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" && url != file {
            var depth: [Bool] = []
            for (number, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("#if ") { depth.append(text == "#if DEBUG") }
                else if text == "#else", depth.popLast() != nil { depth.append(false) }
                else if text == "#endif" { _ = depth.popLast() }
                if line.contains("AgentWindowCapture") {
                    XCTAssertTrue(depth.contains(true), "\(url.lastPathComponent):\(number + 1) names the capture tool outside #if DEBUG")
                }
            }
        }
    }
}
