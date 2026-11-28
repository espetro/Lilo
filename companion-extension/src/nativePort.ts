// Native-messaging plumbing: connects to the peer named by LILO_COMPANION_PEER (set at install
// time by the Linux packaging slice; a bare name here means the host manifest is still missing and
// the extension stays dormant), then serves CompanionRequests from src/protocol.ts with the
// chrome.* tool implementations in tools.ts.

import { errorResponse, parseRequest, successResponse, helloMessage } from "./protocol.ts";
import type { CompanionRequest, CompanionResponse } from "./protocol.ts";
import { dispatchTool } from "./tools.ts";

const PEER_STORAGE_KEY = "companionPeer";

/** Default peer name; packaging overrides it via chrome.storage when policy sets a different one. */
export const DEFAULT_PEER_NAME = "com.getlilo.lilo.companion";

let peerName = DEFAULT_PEER_NAME;
let port: chrome.runtime.Port | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

export function setPeerName(name: string): void {
	peerName = name;
}

export function currentPeerName(): string {
	return peerName;
}

/** Connects to the peer; a port that closes (missing host manifest, peer exit) retries with backoff. */
export function connect(): chrome.runtime.Port | null {
	if (port) return port;
	try {
		port = chrome.runtime.connectNative(peerName);
	} catch {
		scheduleReconnect();
		return null;
	}
	port.onMessage.addListener((message: unknown) => {
		void handlePeerMessage(message);
	});
	port.onDisconnect.addListener(() => {
		port = null;
		scheduleReconnect();
	});
	port.postMessage(helloMessage(peerName));
	return port;
}

function scheduleReconnect(): void {
	if (reconnectTimer) return;
	reconnectTimer = setTimeout(() => {
		reconnectTimer = null;
		connect();
	}, 5000);
}

/** Test hook: stops the reconnect loop so a test worker exits cleanly. */
export function stop(): void {
	if (reconnectTimer) {
		clearTimeout(reconnectTimer);
		reconnectTimer = null;
	}
	port?.disconnect();
	port = null;
}

export async function handlePeerMessage(message: unknown): Promise<CompanionResponse | null> {
	const request = parseRequest(message);
	if ("error" in request) {
		console.warn("[lilo-companion] dropping malformed message:", request.error);
		return null;
	}
	let response: CompanionResponse;
	try {
		response = successResponse(request, await dispatchTool(request));
	} catch (err) {
		response = errorResponse(request, err);
	}
	port?.postMessage(response);
	return response;
}

chrome.storage?.local?.get(PEER_STORAGE_KEY).then((items) => {
	const name = items?.[PEER_STORAGE_KEY];
	if (typeof name === "string" && name.length > 0) setPeerName(name);
	connect();
}).catch(() => connect());

chrome.runtime.onStartup?.addListener(() => connect());
chrome.runtime.onInstalled?.addListener(() => connect());
