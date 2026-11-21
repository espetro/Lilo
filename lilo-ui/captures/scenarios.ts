import { expect, type Page } from "@playwright/test";

import type { FakeHostWorld } from "../e2e/fakeHost";
import type { BridgeLittleState } from "../src/lib/bridge";
import { initialWorld, installFakeHost, pressAndLift, SPACE_1, SPACE_2, splitWorld, tab, treeItem } from "./support";

export interface CaptureScenario {
	name: string;
	world?: FakeHostWorld;
	colorScheme?: "light" | "dark";
	locale?: string;
	/** The page size; the window's own, for a scenario that is not the main window. */
	viewport?: { width: number; height: number };
	/** Boots something other than the main window's chrome. */
	boot?: (page: Page, world: FakeHostWorld) => Promise<void>;
	run: (page: Page) => Promise<void>;
}

// Deterministic chrome-UI scenarios for PR-review media. Each one runs against the fake host,
// so the output only changes when the interface does.
const idle = async () => {};
const sidebarAt = (sidebarWidth: number): FakeHostWorld => ({ ...initialWorld(), sidebarWidth });

const START = { width: 512, height: 380 };
const PAGE = { width: 900, height: 360 };

export const scenarios: CaptureScenario[] = [
	// The sidebar at its narrow, default and wide widths, in both color schemes.
	{ name: "sidebar-narrow-light", world: sidebarAt(200), run: idle },
	{ name: "sidebar-default-light", run: idle },
	{ name: "sidebar-wide-light", world: sidebarAt(400), run: idle },
	{ name: "sidebar-narrow-dark", world: sidebarAt(200), colorScheme: "dark", run: idle },
	{ name: "sidebar-default-dark", colorScheme: "dark", run: idle },
	{ name: "sidebar-wide-dark", world: sidebarAt(400), colorScheme: "dark", run: idle },
	{
		name: "sidebar-spaces",
		run: async (page: Page) => {
			await page.locator(`[data-space-dnd-id="${SPACE_2}"] .space-icon-btn`).click();
			await expect(page.locator('.space-pane [data-tab-id="tab-zeta"]')).toHaveCount(1);
		},
	},
	{
		name: "command-bar",
		run: commandBar,
	},
	{
		name: "command-bar-dark",
		colorScheme: "dark",
		run: commandBar,
	},
	...(["light", "dark"] as const).flatMap((colorScheme) => [
		{ name: `little-start-${colorScheme}`, colorScheme, viewport: START, boot: bootLittle, run: littleStart },
		{ name: `little-results-${colorScheme}`, colorScheme, viewport: START, boot: bootLittle, run: littleResults },
		{ name: `little-page-${colorScheme}`, colorScheme, viewport: PAGE, boot: bootLittle, run: littlePage },
	]),
	...(["light", "dark"] as const).map((colorScheme) => ({ name: `agents-connect-sheet-${colorScheme}`, colorScheme, run: agentsConnectSheet })),
	// Settings > Agents: Connect shows what it will write, writes it, then Remove takes Lilo out again.
	{ name: "agents-connect-flow", run: agentsConnectFlow },
	// The start card, a search, Enter, then the page window's strip: the card grows into the window natively.
	{ name: "little-flow", viewport: { width: 900, height: 640 }, boot: bootLittle, run: littleFlow },
];

const LITTLE_SPACE = { id: "space-home", name: "Home", icon: "🏠", color: "#5865f2" };

// The Little window's chrome, as the native window loads it. The window's own frame color sits behind it.
async function bootLittle(page: Page, world: FakeHostWorld) {
	await installFakeHost(page, world);
	await page.goto("/?little");
	await page.waitForFunction(() => window.__sentCommands?.some((command) => command.action === "littleReady"));
	await sendLittle(page, {});
}

async function sendLittle(page: Page, state: Partial<BridgeLittleState>) {
	const full: BridgeLittleState = {
		mode: "start",
		url: "",
		loading: false,
		space: LITTLE_SPACE,
		otherSpaces: [
			{ id: "space-work", name: "Work", icon: "💼" },
			{ id: "space-play", name: "Play", icon: "🎮" },
		],
		leadingInset: 78,
		...state,
	};
	await page.evaluate((payload) => window.__lilo!.receive({ event: "littleState", ...payload }), full);
	await page.addStyleTag({ content: "html { background: var(--sidebar-bg); }" });
}

async function littleStart(page: Page) {
	await expect(page.locator(".command-bar-input")).toBeFocused();
}

async function littleResults(page: Page) {
	await page.locator(".command-bar-input").pressSequentially("example");
	await expect(page.locator(".command-bar-result.selected")).toBeVisible();
}

// A stand-in for the page under the strip: the capture shows the chrome, never real web content.
async function mockPage(page: Page) {
	await page.evaluate(() => {
		const dark = matchMedia("(prefers-color-scheme: dark)").matches;
		const card = document.createElement("div");
		card.style.cssText = `position:fixed;inset:52px 8px 8px 8px;border-radius:10px;padding:32px;font:15px system-ui;background:${dark ? "#1c1c1e" : "#fff"};color:${dark ? "#f5f5f7" : "#1d1d1f"}`;
		card.innerHTML = "<h1 style='font-size:24px'>Example page</h1><p>A made-up page standing in for the content.</p>";
		document.body.append(card);
	});
}

async function littlePage(page: Page) {
	await sendLittle(page, { mode: "page", url: "https://www.example.com/read", loading: false });
	await mockPage(page);
	await expect(page.locator(".little-bar")).toBeVisible();
	await expect(page.locator(".command-bar-backdrop")).toHaveCount(0);
}

async function littleFlow(page: Page) {
	const input = page.locator(".command-bar-input");
	await expect(input).toBeFocused();
	await expect(input).toHaveAttribute("placeholder", "Search or enter URL...");
	await page.waitForTimeout(600);
	await input.pressSequentially("example.com", { delay: 90 });
	await page.waitForTimeout(700);
	await input.press("Enter");
	await sendLittle(page, { mode: "page", url: "https://www.example.com/", loading: true });
	await page.waitForTimeout(500);
	await mockPage(page);
	await page.waitForTimeout(800);
	await sendLittle(page, { mode: "page", url: "https://www.example.com/", loading: false });
	await page.getByRole("button", { name: "Open in another Space" }).click();
	await page.waitForTimeout(1200);
}

// Ends with the bar open on a query, so the screenshot shows it.
async function commandBar(page: Page) {
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	const input = page.locator(".command-bar-input");
	await input.pressSequentially("beta");
	await expect(page.locator(".command-bar-result.selected")).toContainText("Beta Mail");
}

// A long agent catalog with a featured group, the crowd the picker had to lay out without overlap.
const agentNames = [
	["claude-acp", "Claude Agent", "ACP wrapper for Anthropic's Claude", true],
	["codex-acp", "Codex", "ACP adapter for OpenAI's coding assistant", true],
	["gemini", "Gemini CLI", "Google's official CLI for Gemini", true],
	["github-copilot-cli", "Copilot", "AI pair programmer", true],
	["agoragentic-acp", "Agoragentic", "Agent marketplace with capabilities settled in USDC"],
	["amp-acp", "Amp", "ACP wrapper for Amp"],
	["auggie", "Auggie CLI", "Augment Code's software agent"],
	["autohand", "Autohand Code", "Autohand Code CLI with ACP support"],
	["bob", "Bob", "A development partner"],
	["cline", "Cline", "Coding agent for the editor"],
	["codebuddy-code", "CodeBuddy Code", "An intelligent coding tool"],
	["crow-cli", "crow-cli", "Minimal ACP coding agent"],
	["deepagents", "DeepAgents", "Agent harness for general tasks"],
	["dimcode", "DimCode", "A coding agent that puts models at your command"],
	["dirac", "Dirac", "Reduces API costs with caching"],
	["devin", "Devin", "The software engineer from Cognition"],
	["goose", "goose", "An open source agent that automates tasks"],
	["junie", "Junie", "An autonomous coding agent"],
	["kilo", "Kilo Code", "Open source coding assistant"],
	["kimi", "Kimi", "A coding assistant"],
	["mistral-vibe", "Mistral Vibe", "A coding agent"],
	["opencode", "OpenCode", "Terminal-based coding agent"],
	["qwen-code", "Qwen Code", "A coding CLI"],
	["vtcode", "VT Code", "Semantic code analysis agent"],
] as const;
const agentCatalog = agentNames.map(([id, name, description, featured]) => ({
	id,
	name,
	description,
	...(featured ? { featured: true } : {}),
}));

function receive(page: Page, messages: Record<string, unknown>[]): Promise<void> {
	return page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, messages);
}

// The ask bar's Agent menu open on the crowded catalog. Steps that only exist after a change
// are guarded, so the same scenario still records the earlier layout at a merge base.
async function openAgentPicker(page: Page, query?: string) {
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "openAskBar", selection: "" },
		{ event: "agentCatalog", agents: agentCatalog, projects: ["/Users/example/Code/acme"], home: "/Users/example" },
	]);
	const bar = page.locator(".ask-bar");
	await bar.waitFor({ state: "visible", timeout: 5000 }).catch(() => {});
	await bar.getByRole("button", { name: "Agent", exact: true }).click({ timeout: 5000 }).catch(() => {});
	if (query) await page.locator("[role='menu'] input[type='search']").fill(query, { timeout: 5000 }).catch(() => {});
}

// A web tab split with an agent tab: the conversation pane's header carries its controls.
function agentSplitWorld(): FakeHostWorld {
	const world = splitWorld();
	world.tabsBySpace[SPACE_1].push(
		tab("tab-agent", SPACE_1, { title: "Summarize", url: "", kind: "agent", agentId: "codex-acp" } as never),
	);
	world.foldersBySpace![SPACE_1][0].splitLayout = {
		vertical: false,
		first: { tabId: "tab-alpha" },
		second: { tabId: "tab-agent" },
	};
	world.treeItemsBySpace[SPACE_1] = world.treeItemsBySpace[SPACE_1].filter((item) => item.itemId !== "tab-beta");
	world.treeItemsBySpace[SPACE_1].push(treeItem("tab-agent", SPACE_1, 4, "unpinned", "tab", "folder-split"));
	return world;
}

async function agentSplit(page: Page) {
	await receive(page, [
		{ event: "settingsLoaded", settings: { agentsEnabled: "true" } },
		{ event: "agentCatalog", agents: [{ id: "codex-acp", name: "Codex", description: "" }], projects: [], home: "/Users/example" },
		{
			event: "splitPanesChanged",
			panes: [
				{ tabId: "tab-alpha", x: 0, y: 0, width: 0.5, height: 1 },
				{ tabId: "tab-agent", x: 0.5, y: 0, width: 0.5, height: 1 },
			],
		},
		{
			event: "conversationsChanged",
			conversations: [
				{ tabId: "tab-agent", agentId: "codex-acp", title: "Summarize", state: "idle", unread: false, spaceId: SPACE_1, spaceName: "Work", running: false },
			],
		},
		{ event: "conversationOpened", tabId: "tab-agent", agentId: "codex-acp", cwd: "/Users/example/Code/acme", state: "idle", checkpoints: [], updates: [] },
	]);
	await page.locator(".conversation").waitFor({ state: "visible", timeout: 5000 }).catch(() => {});
}

// A full split grid: the command bar's split hint turns into its "full" note.
async function fullSplitHint(page: Page) {
	await receive(page, [
		{
			event: "splitPanesChanged",
			panes: [
				{ tabId: "tab-alpha", x: 0, y: 0, width: 0.5, height: 0.5 },
				{ tabId: "tab-beta", x: 0.5, y: 0, width: 0.5, height: 0.5 },
				{ tabId: "tab-gamma", x: 0, y: 0.5, width: 0.5, height: 0.5 },
				{ tabId: "tab-wiki", x: 0.5, y: 0.5, width: 0.5, height: 0.5 },
			],
		},
		{ event: "openCommandBar" },
	]);
}

// A pane dragged by its handle onto another pane's center: the drop zone offers the swap.
// The drag is native, so the scenario replays the bridge events it would stream.
async function dragPaneToSwap(page: Page) {
	await receive(page, [
		{
			event: "splitPanesChanged",
			panes: [
				{ tabId: "tab-alpha", x: 0, y: 0, width: 0.5, height: 1 },
				{ tabId: "tab-beta", x: 0.5, y: 0, width: 0.5, height: 1 },
			],
		},
	]);
	for (const [x, y] of [[0.3, 0.5], [0.45, 0.5], [0.58, 0.5], [0.7, 0.5], [0.75, 0.5]] as const) {
		await receive(page, [{ event: "splitPaneDrag", tabId: "tab-alpha", phase: "move", x, y }]);
		await page.waitForTimeout(150);
	}
}

// Dragging a sidebar row over a full split: the drop zone's center target offers the swap.
async function dragOntoSplit(page: Page) {
	await receive(page, [
		{
			event: "splitPanesChanged",
			panes: [
				{ tabId: "tab-alpha", x: 0, y: 0, width: 0.5, height: 1 },
				{ tabId: "tab-beta", x: 0.5, y: 0, width: 0.5, height: 1 },
			],
		},
	]);
	const row = page.locator('.tab-list [data-tab-id="tab-gamma"]');
	await row.waitFor({ state: "visible", timeout: 5000 }).catch(() => {});
	if (!(await row.count())) return;
	await pressAndLift(page, '.tab-list [data-tab-id="tab-gamma"]');
	for (const [x, y] of [[560, 430], [660, 420], [760, 415], [850, 412]] as const) {
		await page.mouse.move(x, y, { steps: 8 });
		await page.waitForTimeout(120);
	}
}

// A sleeping tab beside a kept-loaded one: the dotted ring and the solid one.
async function sleepAndKeptLoaded(page: Page) {
	const world = initialWorld();
	const [sleeping, kept] = [world.tabsBySpace[SPACE_1][1], world.tabsBySpace[SPACE_1][2]];
	await receive(page, [
		{
			event: "browserStatePatch",
			operations: [
				{ kind: "tabUpdated", spaceId: SPACE_1, tab: { ...sleeping, isSleeping: true } },
				{ kind: "tabUpdated", spaceId: SPACE_1, tab: { ...kept, neverSleep: true } },
			],
		},
	]);
}

// A second pinned tab, so Command-click can build a pinned multi-selection.
function twoPinnedWorld(): FakeHostWorld {
	const world = initialWorld();
	world.tabsBySpace[SPACE_1].push(tab("tab-pin2", SPACE_1, { title: "Pinned Tasks", isPinned: true }));
	world.treeItemsBySpace[SPACE_1].splice(2, 0, treeItem("tab-pin2", SPACE_1, 2, "pinned"));
	return world;
}

async function pinnedMultiSelect(page: Page) {
	const alpha = page.locator('.tab-item[data-tab-id="tab-alpha"]');
	const home = page.locator('.tab-item[data-tab-id="tab-home"]');
	const pin2 = page.locator('.tab-item[data-tab-id="tab-pin2"]');
	await pin2.waitFor({ state: "visible", timeout: 5000 }).catch(() => {});
	if (!(await pin2.count())) return;
	await alpha.click();
	await home.click({ modifiers: ["Meta"] });
	await pin2.click({ modifiers: ["Meta"] });
}

async function openCommandBarIdle(page: Page) {
	await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
	await page.locator(".command-bar-input").waitFor();
}

const compactWorld = (): FakeHostWorld => ({ ...initialWorld(), settings: { commandBarLayout: "compact" } });

scenarios.push(
	{ name: "agent-picker-light", run: (page) => openAgentPicker(page) },
	{ name: "agent-picker-dark", colorScheme: "dark", run: (page) => openAgentPicker(page) },
	{ name: "agent-picker-search-light", run: (page) => openAgentPicker(page, "gem") },
	{ name: "agent-picker-search-dark", colorScheme: "dark", run: (page) => openAgentPicker(page, "gem") },
	{ name: "split-agent-light", world: agentSplitWorld(), run: agentSplit },
	{ name: "split-agent-dark", colorScheme: "dark", world: agentSplitWorld(), run: agentSplit },
	{ name: "split-full-hint-light", run: fullSplitHint },
	{ name: "split-full-hint-dark", colorScheme: "dark", run: fullSplitHint },
	{ name: "split-dnd-tab-light", world: splitWorld(), run: dragOntoSplit },
	{ name: "split-dnd-tab-dark", colorScheme: "dark", world: splitWorld(), run: dragOntoSplit },
	{ name: "split-dnd-pane-light", world: splitWorld(), run: dragPaneToSwap },
	{ name: "split-dnd-pane-dark", colorScheme: "dark", world: splitWorld(), run: dragPaneToSwap },
	{ name: "tabs-rings-light", run: sleepAndKeptLoaded },
	{ name: "tabs-rings-dark", colorScheme: "dark", run: sleepAndKeptLoaded },
	{ name: "tabs-pinned-multi-light", world: twoPinnedWorld(), run: pinnedMultiSelect },
	{ name: "tabs-pinned-multi-dark", colorScheme: "dark", world: twoPinnedWorld(), run: pinnedMultiSelect },
	{ name: "cmdbar-scopes-light", run: openCommandBarIdle },
	{ name: "cmdbar-scopes-dark", colorScheme: "dark", run: openCommandBarIdle },
	{ name: "cmdbar-compact-light", world: compactWorld(), run: openCommandBarIdle },
	{ name: "cmdbar-compact-dark", colorScheme: "dark", world: compactWorld(), run: openCommandBarIdle },
);

const CURSOR_CONFIG = "~/.cursor/mcp.json";
const HELPER = "/Applications/Lilo.app/Contents/MacOS/lilo-mcp";
const ADD_LINES = [
	{ number: 3, removed: true, text: "    }" },
	{ number: 3, removed: false, text: "    }," },
	{ number: 4, removed: false, text: '    "lilo" : {' },
	{ number: 5, removed: false, text: `      "command" : "${HELPER}"` },
	{ number: 6, removed: false, text: "    }" },
];
const REMOVE_LINES = [
	{ number: 3, removed: true, text: "    }," },
	{ number: 3, removed: false, text: "    }" },
	{ number: 4, removed: true, text: '    "lilo" : {' },
	{ number: 5, removed: true, text: `      "command" : "${HELPER}"` },
	{ number: 6, removed: true, text: "    }" },
];
const APP_ICON = "data:image/svg+xml;base64," + Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#6b7280"/></svg>').toString("base64");

async function receive(page: Page, event: Record<string, unknown>) {
	await page.evaluate((payload) => window.__lilo!.receive(payload), event);
}

async function openAgents(page: Page, cursorConfigured: boolean) {
	await receive(page, { event: "openSettings" });
	await receive(page, { event: "settingsLoaded", settings: { agentControlEnabled: "true" } });
	await agentClients(page, cursorConfigured);
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();
}

async function agentClients(page: Page, cursorConfigured: boolean) {
	await receive(page, {
		event: "agentClientsLoaded",
		clients: [
			{ id: "claudeCode", configured: true, stale: false, icon: null },
			{ id: "cursor", configured: cursorConfigured, stale: false, icon: APP_ICON },
			{ id: "codex", configured: false, stale: false, icon: null },
		],
		allowed: [],
	});
}

const cursorPreview = (remove: boolean) => ({
	event: "agentClientPreview", client: "cursor", remove, path: CURSOR_CONFIG, command: null,
	snippet: "{}", blocked: null, lines: remove ? REMOVE_LINES : ADD_LINES,
});

async function agentsConnectSheet(page: Page) {
	await openAgents(page, false);
	await page.locator(".agent-tile").filter({ hasText: "Cursor" }).getByRole("button", { name: "Connect" }).click();
	await receive(page, cursorPreview(false));
	await expect(page.locator('[data-modal="agent-config"]')).toBeVisible();
	await page.waitForTimeout(300);
}

async function agentsConnectFlow(page: Page) {
	await openAgents(page, false);
	await page.waitForTimeout(600);
	const cursor = page.locator(".agent-tile").filter({ hasText: "Cursor" });
	await cursor.getByRole("button", { name: "Connect" }).click();
	await receive(page, cursorPreview(false));
	await expect(page.locator('[data-modal="agent-config"]')).toBeVisible();
	await page.waitForTimeout(1800);
	await page.getByRole("button", { name: /Add Lilo/ }).click();
	await agentClients(page, true);
	await receive(page, { event: "settingsActionCompleted", action: "connectAgentClient", message: "Added Lilo to Cursor", level: "info" });
	await page.waitForTimeout(1200);
	await cursor.getByRole("button", { name: "More actions for Cursor" }).click();
	await page.waitForTimeout(500);
	await page.getByRole("menuitem", { name: "Remove Lilo from Cursor…" }).click();
	await receive(page, cursorPreview(true));
	await expect(page.locator('[data-modal="agent-config"]')).toBeVisible();
	await page.waitForTimeout(1800);
	await page.getByRole("button", { name: /Remove Lilo/ }).click();
	await agentClients(page, false);
	await receive(page, { event: "settingsActionCompleted", action: "connectAgentClient", message: "Removed Lilo", level: "info" });
	await page.waitForTimeout(1200);
}
