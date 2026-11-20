import AppKit
import XCTest
@testable import Lilo

/// A conversation pane draws in the chrome web view and registers itself as a `conversation-<tabId>`
/// zone, so its presses classify chrome and would never reach `view(for:)`: the pane could not be
/// click-focused and its native hover pill could not be clicked. These pin the routing that recovers
/// the pane from the zone.
@MainActor
final class SplitPaneChromePressTests: XCTestCase {
    private struct Setup {
        let browser: TemporaryBrowserContext
        let window: MainWindowController
        let webTabId: UUID
        let agentTabId: UUID
        let agentPaneCenter: NSPoint
    }

    private func makeSplit() async throws -> Setup {
        let browser = try await TemporaryBrowserContext()
        let context = browser.context
        let space = try context.spaceManager!.createSpace(name: "Work", profileId: try context.profileManager!.createProfile(name: "Test").id)
        let window = makeTestWindow(context, showing: space.id)
        // The zone lookup converts window points through the views: both need a window home.
        let host = try XCTUnwrap(window.window?.contentView)
        host.addSubview(window.contentContainerView)
        window.chromeWebView.frame = NSRect(origin: .zero, size: NSSize(width: 800, height: 600))
        if window.chromeWebView.superview == nil { host.addSubview(window.chromeWebView) }

        let webTabId = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,web"), activate: false)).id
        window.activateTabStateFirst(id: webTabId)
        let agent = Tab(title: "Summarize", kind: .agent, cwd: NSTemporaryDirectory(), agentId: "claude-acp")
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: agent, activate: false))
        try window.applyBrowserCommand(.splitTabs(spaceId: space.id, tabId: agent.id, targetTabId: webTabId, vertical: false, before: false))

        let split = try XCTUnwrap(window.tabManager.activeSplit)
        _ = window.tabManager.contentView(forTabId: agent.id)
        window.splitPanes.show(split)
        let agentView = try XCTUnwrap(window.tabManager.loadedContentView(forTabId: agent.id))
        let center = window.contentContainerView.convert(
            NSPoint(x: agentView.frame.midX, y: agentView.frame.midY), to: nil)
        return Setup(browser: browser, window: window, webTabId: webTabId, agentTabId: agent.id, agentPaneCenter: center)
    }

    private func registerConversationZone(_ setup: Setup) {
        // The real zone covers the pane's whole rect: reproduce it from the pane's frame through the
        // same coordinate chain the router uses, flipping y for the viewport's top-left origin.
        let window = setup.window, chrome = window.chromeWebView
        let pane = window.tabManager.loadedContentView(forTabId: setup.agentTabId)!.frame
        let inChrome = chrome.convert(window.contentContainerView.convert(pane, to: nil), from: nil)
        let corner = window.chromeInteractiveZones.viewportPoint(
            from: inChrome.origin, in: chrome.bounds, isFlipped: chrome.isFlipped)
        let opposite = window.chromeInteractiveZones.viewportPoint(
            from: NSPoint(x: inChrome.maxX, y: inChrome.maxY), in: chrome.bounds, isFlipped: chrome.isFlipped)
        let rect = NSRect(
            x: min(corner.x, opposite.x), y: min(corner.y, opposite.y),
            width: abs(corner.x - opposite.x), height: abs(corner.y - opposite.y))
        window.chromeInteractiveZones.registerZones([
            (id: "conversation-\(setup.agentTabId.uuidString)", rect: rect),
        ])
    }

    func testChromePressInsideTheConversationZoneFocusesTheAgentPane() async throws {
        let setup = try await makeSplit()
        defer { setup.browser.tearDown() }
        registerConversationZone(setup)

        XCTAssertEqual(setup.window.tabManager.activeOpenTabId, setup.webTabId)
        setup.window.splitPanes.activatePaneForChromePress(atWindowPoint: setup.agentPaneCenter)
        XCTAssertEqual(setup.window.tabManager.activeOpenTabId, setup.agentTabId)
    }

    func testChromePressOutsideAnyConversationZoneChangesNothing() async throws {
        let setup = try await makeSplit()
        defer { setup.browser.tearDown() }
        registerConversationZone(setup)

        // A point in the other pane: no conversation zone there.
        let container = setup.window.contentContainerView
        let webView = try XCTUnwrap(setup.window.tabManager.loadedContentView(forTabId: setup.webTabId))
        let webCenter = container.convert(NSPoint(x: webView.frame.midX, y: webView.frame.midY), to: nil)
        setup.window.splitPanes.activatePaneForChromePress(atWindowPoint: webCenter)
        XCTAssertEqual(setup.window.tabManager.activeOpenTabId, setup.webTabId)

        // Another chrome zone over the agent pane keeps its own press.
        setup.window.chromeInteractiveZones.removeZone(id: "conversation-\(setup.agentTabId.uuidString)")
        let chrome = setup.window.chromeWebView
        let point = setup.window.chromeInteractiveZones.viewportPoint(
            from: chrome.convert(setup.agentPaneCenter, from: nil), in: chrome.bounds, isFlipped: chrome.isFlipped)
        setup.window.chromeInteractiveZones.registerZones([
            (id: "sidebar", rect: NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)),
        ])
        setup.window.splitPanes.activatePaneForChromePress(atWindowPoint: setup.agentPaneCenter)
        XCTAssertEqual(setup.window.tabManager.activeOpenTabId, setup.webTabId)
    }

    func testChromePressOnTheAgentPanePillReachesItsButton() async throws {
        let setup = try await makeSplit()
        defer { setup.browser.tearDown() }
        registerConversationZone(setup)

        // Hover reveals the pane's pill, as updatePointer does on every move; the layout pass
        // positions the pill's buttons, which no run loop does for a test window.
        setup.window.splitPanes.updateHover(atWindowPoint: setup.agentPaneCenter)
        setup.window.contentContainerView.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(setup.window.tabManager.loadedContentView(forTabId: setup.agentTabId)).frame
        // SplitPaneHandleView's close button: 5pt in, 24x22 centered in the 66x26 pill at the pane's top edge.
        let pillPoint = setup.window.contentContainerView.convert(
            NSPoint(x: pane.midX - 33 + 17, y: pane.maxY - 6 - 26 + 13), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: pillPoint, modifierFlags: [], timestamp: 0,
            windowNumber: setup.window.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))

        let button = try XCTUnwrap(setup.window.splitPanes.handleButtonForChromePress(event))
        XCTAssertTrue(button is NSButton)

        // The same press with no conversation zone goes to the chrome, not the pill.
        setup.window.chromeInteractiveZones.removeZone(id: "conversation-\(setup.agentTabId.uuidString)")
        XCTAssertNil(setup.window.splitPanes.handleButtonForChromePress(event))
    }
}
