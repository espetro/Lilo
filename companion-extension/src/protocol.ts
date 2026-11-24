// Wire schema between the companion extension and its native-messaging peer (the Lilo app or a
// headless container). The peer itself is out of scope for now: this module only defines and
// validates the messages, so the host can be written against a stable contract.

/** Agent tools the extension exposes. One message request per tool call. */
export type CompanionTool = "tabs.list" | "tabs.open" | "snapshot" | "scripting.execute";

export interface TabsListParams {
	/** Only tabs whose URL starts with one of these; empty means all. */
	urlPrefixes?: string[];
}

export interface TabsOpenParams {
	url: string;
	/** Open in the background; the tab id is still returned. */
	background?: boolean;
}

export interface SnapshotParams {
	tabId: number;
	/** Body text length cap; the snapshot truncates and sets `truncated`. */
	maxChars?: number;
}

export interface ScriptingExecuteParams {
	tabId: number;
	/** Function source executed in the page's isolated world; must return JSON-serializable data. */
	funcSource: string;
	args?: unknown[];
}

export interface CompanionRequest {
	id: string;
	tool: CompanionTool;
	params: TabsListParams | TabsOpenParams | SnapshotParams | ScriptingExecuteParams;
}

export interface CompanionTabInfo {
	id: number;
	url: string;
	title: string;
	active: boolean;
}

export interface SnapshotResult {
	url: string;
	title: string;
	text: string;
	truncated: boolean;
}

export type CompanionResult =
	| { tool: "tabs.list"; tabs: CompanionTabInfo[] }
	| { tool: "tabs.open"; tabId: number }
	| { tool: "snapshot"; snapshot: SnapshotResult }
	| { tool: "scripting.execute"; result: unknown };

export type CompanionResponse =
	| { id: string; ok: true; tool: CompanionTool; result: CompanionResult }
	| { id: string; ok: false; tool: CompanionTool; error: string };

export const COMPANIED_PROTOCOL_VERSION = 1;

export interface CompanionHello {
	type: "hello";
	protocolVersion: number;
	/** Name of the running peer, reported back for logs; informational. */
	peer: string;
}

/** First message the extension sends once the native-messaging port is open. */
export function helloMessage(peer: string): CompanionHello {
	return { type: "hello", protocolVersion: COMPANIED_PROTOCOL_VERSION, peer };
}

const TOOLS: Record<CompanionTool, string[]> = {
	"tabs.list": ["urlPrefixes?:string[]"],
	"tabs.open": ["url:string", "background?:boolean"],
	"snapshot": ["tabId:number", "maxChars?:number"],
	"scripting.execute": ["tabId:number", "funcSource:string", "args?:unknown[]"],
};

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function typeOf(value: unknown): string {
	if (typeof value === "number") return Number.isFinite(value) ? "number" : "";
	if (typeof value === "string") return "string";
	if (typeof value === "boolean") return "boolean";
	if (Array.isArray(value)) return "unknown[]";
	return "unknown";
}

/** Validates and normalizes a request from the peer; returns an error string when it is malformed. */
export function parseRequest(data: unknown): CompanionRequest | { error: string } {
	if (!isPlainObject(data)) return { error: "request must be an object" };
	const id = data.id;
	if (typeof id !== "string" || id.length === 0) return { error: "request.id must be a non-empty string" };
	const tool = data.tool;
	if (typeof tool !== "string" || !(tool in TOOLS)) return { error: `unknown tool: ${String(tool)}` };
	if (!isPlainObject(data.params)) return { error: "request.params must be an object" };
	const params = data.params;
	const spec = TOOLS[tool as CompanionTool];
	for (const field of spec) {
		const [name, type] = field.split(":");
		const optional = name.endsWith("?");
		const key = optional ? name.slice(0, -1) : name;
		if (!(key in params)) {
			if (!optional) return { error: `${tool} requires params.${key}` };
			continue;
		}
		if (type === "unknown[]") {
			if (!Array.isArray(params[key])) return { error: `params.${key} must be an array` };
		} else if (type.endsWith("[]")) {
			const value = params[key];
			if (!Array.isArray(value) || !value.every((item) => typeOf(item) === type.slice(0, -2))) {
				return { error: `params.${key} must be ${type}` };
			}
		} else if (typeOf(params[key]) !== type) {
			return { error: `params.${key} must be ${type}` };
		}
	}
	return { id, tool: tool as CompanionTool, params } as CompanionRequest;
}

/** Wraps a tool outcome as a success response, or any thrown error as a failure one. */
export function successResponse(request: CompanionRequest, result: CompanionResult): CompanionResponse {
	return { id: request.id, ok: true, tool: request.tool, result };
}

export function errorResponse(request: CompanionRequest, error: unknown): CompanionResponse {
	return { id: request.id, ok: false, tool: request.tool, error: error instanceof Error ? error.message : String(error) };
}
