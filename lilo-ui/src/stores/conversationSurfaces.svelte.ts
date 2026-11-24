import { on } from "../lib/bridge";
import type {
	BridgeConversationSurfaceFailed,
	BridgeConversationSurfaceRequested,
} from "../lib/bridge/protocol";
import { tabActions } from "../lib/bridge/actions";
import { getSidebarsBySpace } from "./sidebar.svelte";

export type ConversationSurfacePlacement = "mini" | "dialog";

export interface ConversationSurface {
	surfaceRequestId: string;
	sourceTabId: string;
	placement: ConversationSurfacePlacement;
	tabId: string | null;
	pending: boolean;
	agentId: string;
	agentName: string;
	error: string | null;
}

interface PendingConversationSurface {
	surfaceRequestId: string;
	sourceTabId: string;
	placement: ConversationSurfacePlacement;
	agentId?: string;
	agentName?: string;
}

// Raw on purpose: a surface is replaced as a unit on every bridge event, and the list stays tiny.
let surfaces = $state.raw<ConversationSurface[]>([]);

export function getConversationSurfaces(): readonly ConversationSurface[] {
	return surfaces;
}

export function getConversationSurfaceBySourceTab(sourceTabId: string): ConversationSurface | null {
	return surfaces.find((surface) => surface.sourceTabId === sourceTabId) ?? null;
}

export function getConversationSurfaceByRequestId(surfaceRequestId: string): ConversationSurface | null {
	return surfaces.find((surface) => surface.surfaceRequestId === surfaceRequestId) ?? null;
}

export function registerPendingConversationSurface(pending: PendingConversationSurface): void {
	if (surfaces.some((surface) => surface.surfaceRequestId === pending.surfaceRequestId)) return;
	// One surface per source tab: the next Ask Bar start replaces the shell or card already there.
	surfaces = [
		...surfaces.filter((surface) => surface.sourceTabId !== pending.sourceTabId),
		{
			surfaceRequestId: pending.surfaceRequestId,
			sourceTabId: pending.sourceTabId,
			placement: pending.placement,
			tabId: null,
			pending: true,
			agentId: pending.agentId ?? "",
			agentName: pending.agentName ?? "",
			error: null,
		},
	];
}

export function handleConversationSurfaceRequested(data: BridgeConversationSurfaceRequested): void {
	const index = surfaces.findIndex((surface) => surface.surfaceRequestId === data.surfaceRequestId);
	const placement = data.placement === "dialog" ? "dialog" : "mini";
	// The source tab still owns one surface: a fallback request replaces whatever was there.
	const kept = surfaces.filter(
		(surface, candidate) => candidate === index || surface.sourceTabId !== data.sourceTabId,
	);
	const nextIndex = kept.findIndex((surface) => surface.surfaceRequestId === data.surfaceRequestId);
	if (nextIndex < 0) {
		surfaces = [
			...kept,
			{
				surfaceRequestId: data.surfaceRequestId,
				sourceTabId: data.sourceTabId,
				placement,
				tabId: data.tabId,
				pending: false,
				agentId: "",
				agentName: "",
				error: null,
			},
		];
		return;
	}
	surfaces = kept.map((surface, candidate) =>
		candidate === nextIndex
			? {
					...surface,
					sourceTabId: data.sourceTabId,
					placement,
					tabId: data.tabId,
					pending: false,
					error: null,
				}
			: surface,
	);
}

export function handleConversationSurfaceFailed(data: BridgeConversationSurfaceFailed): void {
	if (!surfaces.some((surface) => surface.surfaceRequestId === data.surfaceRequestId)) return;
	surfaces = surfaces.map((surface) =>
		surface.surfaceRequestId === data.surfaceRequestId
			? { ...surface, pending: false, error: data.message }
			: surface,
	);
}

export function dismissConversationSurface(surfaceRequestId: string): void {
	if (!surfaces.some((surface) => surface.surfaceRequestId === surfaceRequestId)) return;
	surfaces = surfaces.filter((surface) => surface.surfaceRequestId !== surfaceRequestId);
}

function surfaceForConversation(tabId: string): ConversationSurface | null {
	return surfaces.find((surface) => surface.tabId === tabId) ?? null;
}

export function dismissConversationSurfaceForTab(tabId: string): boolean {
	const surface = surfaceForConversation(tabId);
	if (!surface) return false;
	dismissConversationSurface(surface.surfaceRequestId);
	return true;
}

export function promoteConversationSurface(surfaceRequestId: string): boolean {
	const surface = getConversationSurfaceByRequestId(surfaceRequestId);
	if (!surface?.tabId) return false;
	tabActions.switchTo(surface.tabId);
	dismissConversationSurface(surface.surfaceRequestId);
	return true;
}

export function promoteConversationSurfaceForTab(tabId: string): boolean {
	const surface = surfaceForConversation(tabId);
	return surface ? promoteConversationSurface(surface.surfaceRequestId) : false;
}

function findTab(tabId: string): { isClosed?: boolean } | undefined {
	for (const state of Object.values(getSidebarsBySpace())) {
		const tab = state.tabs.find((candidate) => candidate.id === tabId);
		if (tab) return tab;
	}
	return undefined;
}

function reconcileConversationSurfaces(): void {
	const sidebars = getSidebarsBySpace();
	if (!Object.values(sidebars).some((state) => state.hydrated)) return;
	const next = surfaces.filter((surface) => {
		const source = findTab(surface.sourceTabId);
		if (!source || source.isClosed) return false;
		if (!surface.tabId) return true;
		const conversation = findTab(surface.tabId);
		return !!conversation && !conversation.isClosed;
	});
	if (next.length !== surfaces.length) surfaces = next;
}

let initialized = false;

export function initConversationSurfacesStore(): void {
	if (initialized) return;
	initialized = true;

	on("conversationSurfaceRequested", handleConversationSurfaceRequested);
	on("conversationSurfaceFailed", handleConversationSurfaceFailed);
	// Registered after the sidebar store's listeners, so a tab close or Space switch is already applied.
	on("browserStateChanged", reconcileConversationSurfaces);
	on("browserStatePatch", reconcileConversationSurfaces);
	on("spaceDeleted", reconcileConversationSurfaces);
}
