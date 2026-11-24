import AppKit
import XCTest
@testable import Lilo

/// Where `startConversation` puts a new conversation: a plain activated tab, a split beside the source
/// page, or an inactive tab the chrome's mini/dialog surface takes over. The surface events are what
/// pair a delayed start with the pending surface, so they are asserted alongside the tab state.
@MainActor
final class ConversationPlacementTests: XCTestCase {
    private struct Setup {
        let browser: TemporaryBrowserContext
        let context: BrowserContext
        let space: Space
        let window: MainWindowController
        let webTabId: UUID
    }

    private func makeSetup() async throws -> Setup {
        let browser = try await TemporaryBrowserContext()
        let context = browser.context
        let space = try context.spaceManager!.createSpace(name: "Work", profileId: try context.profileManager!.createProfile(name: "Test").id)
        let window = makeTestWindow(context, showing: space.id)
        context.settingsStore!.set("agentsEnabled", value: "true")
        let webTabId = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,web"), activate: false)).id
        window.activateTabStateFirst(id: webTabId)
        return Setup(browser: browser, context: context, space: space, window: window, webTabId: webTabId)
    }

    /// The router ships queued sends on the next main-loop turn.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func conversationFolder(of tabId: UUID, in setup: Setup) -> TabFolder? {
        setup.window.tabManager.folders(forSpace: setup.space.id).first { $0.conversationTabId == tabId }
    }

    private func sidebarParent(of tabId: UUID, in setup: Setup) -> UUID? {
        setup.window.tabManager.sidebarTreeItems(forSpace: setup.space.id)
            .first { $0.kind == .tab && $0.itemId == tabId }?.parentFolderId
    }

    func testNoPlacementStartsAnActivatedTabInItsFolder() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }
        let recorder = BridgeEventRecorder(setup.window.bridgeRouter)

        let conversation = try XCTUnwrap(await setup.window.startConversation(agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true))

        XCTAssertEqual(setup.window.tabManager.activeTab?.id, conversation.id)
        let folder = try XCTUnwrap(conversationFolder(of: conversation.id, in: setup))
        XCTAssertEqual(sidebarParent(of: conversation.id, in: setup), folder.id)
        settle()
        XCTAssertTrue(recorder.events.isEmpty, "a plain tab start announces no surface")
    }

    func testTabPlacementStartsAnActivatedTabInItsFolder() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }

        let conversation = try XCTUnwrap(await setup.window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true, placement: "tab"
        ))

        XCTAssertEqual(setup.window.tabManager.activeTab?.id, conversation.id)
        XCTAssertEqual(sidebarParent(of: conversation.id, in: setup), conversationFolder(of: conversation.id, in: setup)?.id)
    }

    func testMiniPlacementLeavesTheTabInactiveAndRequestsTheSurface() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }
        let recorder = BridgeEventRecorder(setup.window.bridgeRouter)

        let conversation = try XCTUnwrap(await setup.window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true,
            placement: "mini", sourceTabId: setup.webTabId, surfaceRequestId: "req-1"
        ))

        XCTAssertEqual(setup.window.tabManager.activeTab?.id, setup.webTabId, "the page keeps the focus")
        XCTAssertEqual(sidebarParent(of: conversation.id, in: setup), conversationFolder(of: conversation.id, in: setup)?.id)
        settle()
        let requests = recorder.events.filter { $0.name == "conversationSurfaceRequested" }.map(\.data)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["tabId"] as? String, conversation.id.uuidString)
        XCTAssertEqual(requests.first?["sourceTabId"] as? String, setup.webTabId.uuidString)
        XCTAssertEqual(requests.first?["placement"] as? String, "mini")
        XCTAssertEqual(requests.first?["surfaceRequestId"] as? String, "req-1")
    }

    func testDialogPlacementLeavesTheTabInactiveAndRequestsTheSurface() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }
        let recorder = BridgeEventRecorder(setup.window.bridgeRouter)

        let conversation = try XCTUnwrap(await setup.window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true, placement: "dialog", sourceTabId: setup.webTabId
        ))

        XCTAssertEqual(setup.window.tabManager.activeTab?.id, setup.webTabId)
        settle()
        let requests = recorder.events.filter { $0.name == "conversationSurfaceRequested" }.map(\.data)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["placement"] as? String, "dialog")
        XCTAssertEqual(requests.first?["tabId"] as? String, conversation.id.uuidString)
    }

    func testMiniWithoutAnEligibleSourceFallsBackToTab() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }
        let recorder = BridgeEventRecorder(setup.window.bridgeRouter)

        // A source tab that does not exist binds nothing: the conversation opens as a tab instead.
        let conversation = try XCTUnwrap(await setup.window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true,
            placement: "mini", sourceTabId: UUID(), surfaceRequestId: "req-2"
        ))

        XCTAssertEqual(setup.window.tabManager.activeTab?.id, conversation.id)
        settle()
        XCTAssertFalse(recorder.events.contains { $0.name == "conversationSurfaceRequested" })
    }

    func testSplitPlacementPanesTheConversationBesideTheSource() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }
        let recorder = BridgeEventRecorder(setup.window.bridgeRouter)

        let conversation = try XCTUnwrap(await setup.window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true,
            placement: "split", sourceTabId: setup.webTabId
        ))

        let split = try XCTUnwrap(setup.context.browserState.space(id: setup.space.id)?.spaceTab.splitGroup(containing: conversation.id))
        guard case let .split(vertical, ratio, first, second) = split.layout else { return XCTFail("expected a two-pane split") }
        XCTAssertFalse(vertical)
        XCTAssertEqual(ratio, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(first.paneIds, [setup.webTabId])
        XCTAssertEqual(second.paneIds, [conversation.id])
        XCTAssertEqual(setup.window.tabManager.activeTab?.id, conversation.id, "the split activates the conversation pane")
        // The conversation keeps its own folder for the pages the agent opens; the marked tab lets the
        // chrome and the context menu find it outside the split.
        let folder = try XCTUnwrap(conversationFolder(of: conversation.id, in: setup))
        XCTAssertNotEqual(folder.id, split.folderId)
        XCTAssertEqual(setup.context.conversations.conversations[conversation.id]?.folderId, folder.id)
        XCTAssertEqual(setup.window.conversationTab(inFolder: folder)?.id, conversation.id)
        settle()
        XCTAssertFalse(recorder.events.contains { $0.name == "conversationSurfaceRequested" }, "a real split announces no surface")
    }

    func testSplitThatCannotBeMadeFallsBackToDialog() async throws {
        let browser = try await TemporaryBrowserContext()
        defer { browser.tearDown() }
        let context = browser.context
        let space = try context.spaceManager!.createSpace(name: "Work", profileId: try context.profileManager!.createProfile(name: "Test").id)
        let window = makeTestWindow(context, showing: space.id)
        context.settingsStore!.set("agentsEnabled", value: "true")
        // A source tab that was never activated leaves the window with no active pane to split against:
        // splitTab refuses, and the start degrades to the dialog surface.
        let webTabId = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,web"), activate: false)).id
        let recorder = BridgeEventRecorder(window.bridgeRouter)

        let conversation = try XCTUnwrap(await window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true,
            placement: "split", sourceTabId: webTabId, surfaceRequestId: "req-3"
        ))

        XCTAssertNotEqual(window.tabManager.activeTab?.id, conversation.id, "the dialog surface leaves the tab inactive")
        settle()
        let requests = recorder.events.filter { $0.name == "conversationSurfaceRequested" }.map(\.data)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["placement"] as? String, "dialog")
        XCTAssertEqual(requests.first?["sourceTabId"] as? String, webTabId.uuidString)
        XCTAssertEqual(requests.first?["surfaceRequestId"] as? String, "req-3")
    }

    func testBackgroundStartNeitherActivatesNorAnnouncesASurface() async throws {
        let setup = try await makeSetup()
        defer { setup.browser.tearDown() }
        let recorder = BridgeEventRecorder(setup.window.bridgeRouter)

        let conversation = try XCTUnwrap(await setup.window.startConversation(
            agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: false,
            placement: "mini", sourceTabId: setup.webTabId, surfaceRequestId: "req-4"
        ))

        XCTAssertEqual(setup.window.tabManager.activeTab?.id, setup.webTabId)
        XCTAssertEqual(sidebarParent(of: conversation.id, in: setup), conversationFolder(of: conversation.id, in: setup)?.id)
        settle()
        XCTAssertTrue(recorder.events.isEmpty, "a background start opens no surface")
    }
}
