// The chrome.* implementations behind each CompanionTool. Thin on purpose: no caching, no retries
// beyond what the port layer already does, so every tool call maps to one observable browser action.

import type {
	CompanionRequest,
	CompanionResult,
	CompanionTabInfo,
	SnapshotParams,
	ScriptingExecuteParams,
	SnapshotResult,
	TabsListParams,
	TabsOpenParams,
} from "./protocol.ts";

async function listTabs(params: TabsListParams): Promise<CompanionResult> {
	const prefixes = params.urlPrefixes ?? [];
	const tabs = await chrome.tabs.query({});
	const matching: CompanionTabInfo[] = tabs
		.filter((tab) => prefixes.length === 0 || prefixes.some((prefix) => (tab.url ?? "").startsWith(prefix)))
		.map((tab) => ({ id: tab.id ?? -1, url: tab.url ?? "", title: tab.title ?? "", active: tab.active ?? false }));
	return { tool: "tabs.list", tabs: matching };
}

async function openTab(params: TabsOpenParams): Promise<CompanionResult> {
	const tab = await chrome.tabs.create({ url: params.url, active: params.background !== true });
	return { tool: "tabs.open", tabId: tab.id ?? -1 };
}

// chrome-types types `func` as () => void, but the API serializes any function and passes args.
type ExecuteScript = (injection: {
	target: { tabId: number };
	func: (...args: never[]) => unknown;
	args?: unknown[];
}) => Promise<{ result?: unknown }[]>;

async function snapshotPage(params: SnapshotParams): Promise<CompanionResult> {
	const maxChars = params.maxChars ?? 50_000;
	// Injected into the page's isolated world: the page cannot see it, and it only reads the DOM.
	const executeScript = chrome.scripting.executeScript as unknown as ExecuteScript;
	const injection = await executeScript({
		target: { tabId: params.tabId },
		func: extractSnapshot,
		args: [maxChars],
	});
	const value = (injection[0]?.result ?? null) as Omit<SnapshotResult, "truncated"> | null;
	if (!value) throw new Error(`snapshot of tab ${params.tabId} returned no result`);
	return { tool: "snapshot", snapshot: { ...value, truncated: value.text.length >= maxChars } };
}

function extractSnapshot(maxChars: number): { url: string; title: string; text: string } {
	return {
		url: location.href,
		title: document.title,
		text: (document.body?.innerText ?? "").slice(0, maxChars),
	};
}

async function executeScriptTool(params: ScriptingExecuteParams): Promise<CompanionResult> {
	const executeScript = chrome.scripting.executeScript as unknown as ExecuteScript;
	const injection = await executeScript({
		target: { tabId: params.tabId },
		// funcSource is agent-authored code executed in the isolated world; the page cannot see it
		// and it has no chrome.* beyond what scripting grants. Validated by construction: the
		// browser compiles it, and a syntax error surfaces as a rejected injection.
		func: (source: string, args: unknown[]) =>
			(new Function(`return (${source})`)() as (...a: unknown[]) => unknown)(...args),
		args: [params.funcSource, params.args ?? []],
	});
	return { tool: "scripting.execute", result: injection[0]?.result };
}

const DISPATCH: Record<CompanionRequest["tool"], (params: never) => Promise<CompanionResult>> = {
	"tabs.list": listTabs,
	"tabs.open": openTab,
	"snapshot": snapshotPage,
	"scripting.execute": executeScriptTool,
};

export function dispatchTool(request: CompanionRequest): Promise<CompanionResult> {
	return DISPATCH[request.tool](request.params as never);
}
