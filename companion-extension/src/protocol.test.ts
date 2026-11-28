// Tests for the wire schema between the extension and its native-messaging peer.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
	COMPANIED_PROTOCOL_VERSION,
	errorResponse,
	helloMessage,
	parseRequest,
	successResponse,
} from "./protocol.ts";
import { dispatchTool } from "./tools.ts";

describe("parseRequest", () => {
	test("accepts a valid snapshot request", () => {
		const parsed = parseRequest({ id: "r1", tool: "snapshot", params: { tabId: 3, maxChars: 100 } });
		assert.deepEqual(parsed, { id: "r1", tool: "snapshot", params: { tabId: 3, maxChars: 100 } });
	});

	test("accepts optional params being absent", () => {
		const parsed = parseRequest({ id: "r2", tool: "tabs.list", params: {} });
		assert.deepEqual(parsed, { id: "r2", tool: "tabs.list", params: {} });
	});

	test("rejects a non-object, a missing id and an empty id", () => {
		for (const bad of [null, "x", 7, { tool: "snapshot", params: {} }, { id: "", tool: "snapshot", params: {} }]) {
			assert.ok("error" in (parseRequest(bad) as { error: string }), `expected rejection of ${JSON.stringify(bad)}`);
		}
	});

	test("rejects an unknown tool", () => {
		const parsed = parseRequest({ id: "r3", tool: "cookies.read", params: {} });
		assert.ok("error" in parsed);
		assert.match(parsed.error, /unknown tool/);
	});

	test("rejects params that are not an object or of the wrong type", () => {
		const wrongType = parseRequest({ id: "r4", tool: "snapshot", params: { tabId: "3" } });
		assert.ok("error" in wrongType);
		assert.match(wrongType.error, /tabId must be number/);
		const notObject = parseRequest({ id: "r5", tool: "snapshot", params: [1] });
		assert.ok("error" in notObject);
		assert.match(notObject.error, /params must be an object/);
	});

	test("rejects a required param left out and a non-finite number", () => {
		const missing = parseRequest({ id: "r6", tool: "tabs.open", params: {} });
		assert.ok("error" in missing);
		assert.match(missing.error, /requires params\.url/);
		const nonFinite = parseRequest({ id: "r7", tool: "snapshot", params: { tabId: NaN } });
		assert.ok("error" in nonFinite);
		assert.match(nonFinite.error, /tabId must be number/);
	});

	test("accepts arrays only where the schema says array", () => {
		const ok = parseRequest({ id: "r8", tool: "tabs.list", params: { urlPrefixes: ["https://example.com/"] } });
		assert.ok(!("error" in ok));
		const bad = parseRequest({ id: "r9", tool: "scripting.execute", params: { tabId: 1, funcSource: "()", args: "x" } });		assert.ok("error" in bad && bad.error !== undefined);
		assert.match(bad.error, /args must be an array/);
	});
});

describe("responses", () => {
	test("helloMessage carries the protocol version and peer", () => {
		assert.deepEqual(helloMessage("test-peer"), {
			type: "hello",
			protocolVersion: COMPANIED_PROTOCOL_VERSION,
			peer: "test-peer",
		});
	});

	test("successResponse echoes the request id and tool", () => {
		const request = { id: "r10", tool: "tabs.open" as const, params: { url: "https://example.com/" } };
		const response = successResponse(request, { tool: "tabs.open", tabId: 5 });
		assert.deepEqual(response, { id: "r10", ok: true, tool: "tabs.open", result: { tool: "tabs.open", tabId: 5 } });
	});

	test("errorResponse turns a thrown Error into its message and anything else into a string", () => {
		const request = { id: "r11", tool: "snapshot" as const, params: { tabId: 1 } };
		assert.deepEqual(errorResponse(request, new Error("no such tab")), {
			id: "r11", ok: false, tool: "snapshot", error: "no such tab",
		});
		const failure = errorResponse(request, 42);
		assert.ok(!failure.ok);
		assert.match(failure.error, /42/);
	});
});

describe("dispatchTool", () => {
	test("serves every schema tool with a stubbed chrome namespace", async () => {
		const tabs = [
			{ id: 1, url: "https://example.com/a", title: "A", active: true },
			{ id: 2, url: "https://other.example/b", title: "B", active: false },
		];
		const globalChrome = globalThis as { chrome?: unknown };
		globalChrome.chrome = {
			tabs: {
				query: async () => tabs,
				create: async ({ url, active }: { url: string; active: boolean }) => ({ id: 9, url, active }),
			},
			scripting: {
				executeScript: async ({ func, args }: { func: (...a: unknown[]) => unknown; args: unknown[] }) => [
					{ result: func(...args) },
				],
			},
		};
		try {
			assert.deepEqual(
				await dispatchTool({ id: "d1", tool: "tabs.list", params: { urlPrefixes: ["https://example.com/"] } }),
				{ tool: "tabs.list", tabs: [{ id: 1, url: "https://example.com/a", title: "A", active: true }] },
			);
			assert.deepEqual(
				await dispatchTool({ id: "d2", tool: "tabs.list", params: {} }),
				{
					tool: "tabs.list",
					tabs: [
						{ id: 1, url: "https://example.com/a", title: "A", active: true },
						{ id: 2, url: "https://other.example/b", title: "B", active: false },
					],
				},
			);
			assert.deepEqual(await dispatchTool({ id: "d3", tool: "tabs.open", params: { url: "https://example.com/" } }), {
				tool: "tabs.open",
				tabId: 9,
			});
			const executed = await dispatchTool({
				id: "d4",
				tool: "scripting.execute",
				params: { tabId: 1, funcSource: "() => 1 + 1", args: [] },
			});
			assert.deepEqual(executed, { tool: "scripting.execute", result: 2 });
			await assert.rejects(
				dispatchTool({ id: "d5", tool: "scripting.execute", params: { tabId: 1, funcSource: "not javascript (", args: [] } }),
			);
		} finally {
			delete globalChrome.chrome;
		}
	});
});
