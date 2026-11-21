#if DEBUG
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Debug builds only: renders Lilo's own main window to PNG files for pull request media of native changes.
/// Everything is drawn in this process (AppKit's view cache plus WebKit's own snapshots), so it needs no screen
/// permission, sees no other app's pixels, and never activates or moves the window. A Release build has no
/// trace of it: the whole file is compiled out.
@MainActor
enum AgentWindowCapture {
    static let name = "window_capture"
    /// What the Debug app answers to a capture that names no size.
    static let defaultSize = CGSize(width: 1280, height: 800)
    /// The rail is the one sidebar "width" that is a state of its own.
    static let rail = "rail"

    static let definition = AgentTools.tool(name, """
        Debug build only. Renders Lilo's own main window (chrome, tab content and the window buttons) to a PNG at \
        `path`, drawn inside the app: no screen permission, no focus change. The window is resized to width x height \
        (1280x800 by default) for the capture and put back. With `sidebarWidths` (numbers, or "rail"), the sidebar is \
        dragged to each width in turn, as a user would, and one PNG per width is written next to `path` as \
        <name>-<width>.png; `gif` also writes them as one looping animation. The sidebar goes back to its width after.
        """, [
            "path": AgentTools.prop("string", "Absolute path of the PNG."),
            "width": AgentTools.prop("number", "Window content width in points, 1280 by default."),
            "height": AgentTools.prop("number", "Window content height in points, 800 by default."),
            "sidebarWidths": ["type": "array", "items": ["type": ["number", "string"]],
                              "description": "Sidebar widths to capture, in points or \"rail\"."],
            "gif": AgentTools.prop("string", "Absolute path of a GIF of the sidebarWidths shots, 1 s a frame."),
            "settleMs": AgentTools.prop("number", "Wait before each shot, 500 by default."),
            "littleWindow": AgentTools.prop("boolean", "Capture a Little window instead: one is opened on the command bar, and closed again after the shot."),
            "littleQuery": AgentTools.prop("string", "With littleWindow: text typed in its command bar before the shot."),
            "littleUrl": AgentTools.prop("string", "With littleWindow: an http, https or file URL the command bar opens, so the shot is the page window.")
        ], required: ["path"])

    static func call(_ tool: String, arguments: [String: Any], control: AgentControl) async throws -> [AgentContent]? {
        guard tool == name else { return nil }
        guard let path = arguments["path"] as? String, path.hasPrefix("/"), (path as NSString).pathExtension.lowercased() == "png" else {
            throw AgentToolError("path is an absolute path ending in .png")
        }
        let gifPath = arguments["gif"] as? String
        if let gifPath, !gifPath.hasPrefix("/") || (gifPath as NSString).pathExtension.lowercased() != "gif" {
            throw AgentToolError("gif is an absolute path ending in .gif")
        }
        guard let controller = control.context?.windows.activeWindow, let window = controller.window else {
            throw AgentToolError("There is no Lilo window to capture")
        }
        let size = CGSize(width: (arguments["width"] as? NSNumber).map { CGFloat(truncating: $0) } ?? defaultSize.width,
                          height: (arguments["height"] as? NSNumber).map { CGFloat(truncating: $0) } ?? defaultSize.height)
        let settle = Duration.milliseconds(min(max((arguments["settleMs"] as? NSNumber)?.intValue ?? 500, 0), 10_000))
        let widths = (arguments["sidebarWidths"] as? [Any] ?? []).compactMap { value -> String? in
            if let text = value as? String { return text == rail ? rail : Int(text).map(String.init) }
            return (value as? NSNumber).map { String($0.intValue) }
        }

        if arguments["littleWindow"] as? Bool == true {
            return try await captureLittleWindow(to: path, arguments: arguments, controller: controller, settle: settle)
        }
        let savedFrame = window.frame
        let savedWidth = controller.sidebarRail ? rail : String(Int(controller.sidebarExpandedWidth))
        window.setContentSize(size)

        var images: [CGImage] = []
        var written: [String] = []
        let base = (path as NSString).deletingPathExtension
        do {
            for target in widths.isEmpty ? [nil] : widths.map({ Optional($0) }) {
                if let target { try await dragSidebar(to: target, in: controller) }
                try await Task.sleep(for: settle)
                guard let image = await render(window) else { throw AgentToolError("The window could not be drawn") }
                let file = target.map { "\(base)-\($0).png" } ?? path
                try write(image, to: file)
                images.append(image)
                written.append("\(file) (\(image.width)x\(image.height))")
            }
        } catch {
            window.setFrame(savedFrame, display: true)
            throw error
        }
        window.setFrame(savedFrame, display: true)
        if !widths.isEmpty { try await dragSidebar(to: savedWidth, in: controller) }
        if let gifPath, images.count > 1 {
            try writeGIF(images, to: gifPath)
            written.append(gifPath)
        }
        return [.text("Captured the window at \(Int(size.width))x\(Int(size.height)): " + written.joined(separator: ", "))]
    }

    /// A Little window opened for the shot: on the command bar, with `littleQuery` typed in it, or turned into the page
    /// window by `littleUrl`. The window keeps its own size.
    private static func captureLittleWindow(to path: String, arguments: [String: Any], controller: MainWindowController, settle: Duration) async throws -> [AgentContent]? {
        guard let little = controller.openLittleWindow(url: nil) else { throw AgentToolError("A Little window could not be opened") }
        defer { little.window.close() }
        for _ in 0..<100 where !little.isChromeReady { try await Task.sleep(for: .milliseconds(50)) }
        guard little.isChromeReady else { throw AgentToolError("The Little window's chrome did not load") }
        if let query = arguments["littleQuery"] as? String {
            _ = try await little.chromeView.callAsyncJavaScript("""
                const input = document.querySelector('.command-bar-input');
                input.focus();
                input.value = query;
                input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: query }));
                """, arguments: ["query": query], contentWorld: .page)
        }
        if let address = arguments["littleUrl"] as? String, let url = URL(string: address) { little.navigate(to: url) }
        try await Task.sleep(for: settle + .milliseconds(arguments["littleUrl"] == nil ? 0 : 1_500))
        guard let image = await render(little.window) else { throw AgentToolError("The window could not be drawn") }
        try write(image, to: path)
        return [.text("Captured the Little window (\(little.mode == .page ? "page" : "start card")): \(path) (\(image.width)x\(image.height))")]
    }

    /// The window's frame view (titlebar and window buttons included) drawn by AppKit, then each web view over it
    /// as WebKit paints it, in view order: a web view's pixels live in its own process and never reach the cache.
    static func render(_ window: NSWindow) async -> CGImage? {
        guard let frameView = unsafe window.contentView?.superview else { return nil }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        frameView.cacheDisplay(in: bounds, to: rep)
        var snapshots: [(NSImage, CGRect)] = []
        for webView in visibleWebViews(in: frameView) {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            if let image = try? await webView.takeSnapshot(configuration: configuration) {
                snapshots.append((image, webView.convert(webView.bounds, to: frameView)))
            }
        }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep.cgImage }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (image, rect) in snapshots {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func visibleWebViews(in view: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        for subview in view.subviews where !subview.isHidden && subview.alphaValue > 0 {
            if let webView = subview as? WKWebView { found.append(webView) } else { found += visibleWebViews(in: subview) }
        }
        return found
    }

    /// Drags the resize handle in the chrome page the way a user does (mouse down, move, up), so the page, the
    /// window buttons and the saved width all follow the app's own code. A rail unfolds before any other drag.
    private static func dragSidebar(to target: String, in controller: MainWindowController) async throws {
        let script = """
            (target) => {
              const root = document.documentElement;
              const handle = document.querySelector('.sidebar-resize-handle') ?? document.querySelector('[role=separator]');
              if (!handle) return 'no resize handle';
              const right = root.dataset.tabPosition === 'right';
              const drag = (from, to) => {
                const at = x => ({ clientX: x, clientY: 300, bubbles: true, cancelable: true, button: 0 });
                handle.dispatchEvent(new MouseEvent('mousedown', at(1000)));
                window.dispatchEvent(new MouseEvent('mousemove', at(1000 + (right ? -1 : 1) * (to - from))));
                window.dispatchEvent(new MouseEvent('mouseup', at(1000 + (right ? -1 : 1) * (to - from))));
              };
              const current = () => parseInt(getComputedStyle(root).getPropertyValue('--sidebar-width')) || 260;
              const folded = () => root.dataset.sidebarRail !== undefined;
              if (target === 'rail') { drag(current(), 0); return 'ok'; }
              if (folded()) drag(40, 480);
              drag(current(), Number(target));
              return 'ok';
            }
            """
        let result = try await controller.chromeWebView.callAsyncJavaScript(
            "return (\(script))(target)", arguments: ["target": target], contentWorld: .page
        )
        if let result = result as? String, result != "ok" { throw AgentToolError("The sidebar could not be dragged: \(result)") }
    }

    private static func write(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentToolError("Could not write \(path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentToolError("Could not write \(path)") }
    }

    private static func writeGIF(_ images: [CGImage], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else {
            throw AgentToolError("Could not write \(path)")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw AgentToolError("Could not write \(path)") }
    }
}
#endif
