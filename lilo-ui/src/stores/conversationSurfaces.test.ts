import assert from "node:assert/strict";
import test from "node:test";
import type { BridgeInitialStatePayload } from "../lib/bridge/protocol";
import { tab } from "./testFixtures";
import { freshStores, stubBridgeWindow } from "./testHarness";

const SPACE = "space";

function initialState(tabs: ReturnType<typeof tab>[]): BridgeInitialStatePayload {
	return {
		activeSpaceId: SPACE,
		activeTabId: tabs[0]?.id ?? "",
		sidebarWidth: 0,
		sidebarVisible: true,
		spaces: [
			{
				id: SPACE,
				name: "Space",
				icon: "S",
				color: "#5865f2",
				profileId: "profile",
				isPrivate: false,
				sortOrder: 0,
			},
		],
		tabs,
		folders: [],
		treeItems: [],
	};
}

function receive(payload: Record<string, unknown>): void {
	(
		globalThis as {
			window: { __lilo?: { receive(msg: Record<string, unknown>): void } };
		}
	).window.__lilo?.receive(payload);
}

test("pending surface matches its request and promotes to the conversation tab", async () => {
	const posted = stubBridgeWindow();
	const loadStore = await freshStores();
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	const { initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const surfaces = await loadStore("/src/stores/conversationSurfaces.svelte.ts");
	initTabStore();
	surfaces.initConversationSurfacesStore();
	applySidebarTabInitialState(initialState([tab("source", SPACE), tab("conversation", SPACE, { kind: "agent" })]));

	surfaces.registerPendingConversationSurface({
		surfaceRequestId: "req-1",
		sourceTabId: "source",
		placement: "mini",
		agentId: "agent",
		agentName: "Agent",
	});
	assert.equal(surfaces.getConversationSurfaceBySourceTab("source")?.pending, true);

	receive({
		event: "conversationSurfaceRequested",
		tabId: "conversation",
		sourceTabId: "source",
		placement: "mini",
		surfaceRequestId: "req-1",
	});
	const surface = surfaces.getConversationSurfaceBySourceTab("source");
	assert.equal(surface?.tabId, "conversation");
	assert.equal(surface?.pending, false);

	assert.equal(surfaces.promoteConversationSurfaceForTab("conversation"), true);
	assert.equal(surfaces.getConversationSurfaces().length, 0);
	assert.deepEqual(posted.at(-1), { action: "switchTab", payload: { id: "conversation" } });
});

test("a new pending surface replaces the one bound to the same source tab", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	const { initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const surfaces = await loadStore("/src/stores/conversationSurfaces.svelte.ts");
	initTabStore();
	surfaces.initConversationSurfacesStore();
	applySidebarTabInitialState(initialState([tab("source", SPACE)]));

	surfaces.registerPendingConversationSurface({ surfaceRequestId: "req-1", sourceTabId: "source", placement: "mini" });
	receive({
		event: "conversationSurfaceRequested",
		tabId: "conversation-1",
		sourceTabId: "source",
		placement: "mini",
		surfaceRequestId: "req-1",
	});
	surfaces.registerPendingConversationSurface({ surfaceRequestId: "req-2", sourceTabId: "source", placement: "dialog" });

	const all = surfaces.getConversationSurfaces();
	assert.equal(all.length, 1);
	assert.equal(all[0].surfaceRequestId, "req-2");
	assert.equal(all[0].placement, "dialog");
});

test("failure marks the pending surface and dismissal removes it", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	const { initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const surfaces = await loadStore("/src/stores/conversationSurfaces.svelte.ts");
	initTabStore();
	surfaces.initConversationSurfacesStore();
	applySidebarTabInitialState(initialState([tab("source", SPACE)]));

	surfaces.registerPendingConversationSurface({ surfaceRequestId: "req-1", sourceTabId: "source", placement: "dialog" });
	receive({ event: "conversationSurfaceFailed", surfaceRequestId: "req-1", message: "No agent" });
	assert.equal(surfaces.getConversationSurfaceByRequestId("req-1")?.error, "No agent");

	surfaces.dismissConversationSurface("req-1");
	assert.equal(surfaces.getConversationSurfaces().length, 0);
});

test("closing the source or conversation tab removes the surface", async () => {
	stubBridgeWindow();
	const loadStore = await freshStores();
	const { applySidebarTabInitialState } = await loadStore("/src/stores/sidebar.svelte.ts");
	const { initTabStore } = await loadStore("/src/stores/tabs.svelte.ts");
	const surfaces = await loadStore("/src/stores/conversationSurfaces.svelte.ts");
	initTabStore();
	surfaces.initConversationSurfacesStore();
	applySidebarTabInitialState(initialState([tab("source", SPACE), tab("conversation", SPACE, { kind: "agent" })]));

	surfaces.registerPendingConversationSurface({ surfaceRequestId: "req-1", sourceTabId: "source", placement: "mini" });
	receive({
		event: "conversationSurfaceRequested",
		tabId: "conversation",
		sourceTabId: "source",
		placement: "mini",
		surfaceRequestId: "req-1",
	});

	receive({
		event: "browserStateChanged",
		changedSpaceId: SPACE,
		states: [
			{
				spaceId: SPACE,
				activeTabId: "source",
				tabs: [tab("source", SPACE)],
				folders: [],
				treeItems: [],
			},
		],
	});
	assert.equal(surfaces.getConversationSurfaces().length, 0);
});
