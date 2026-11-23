import { expect, type Page } from "@playwright/test";

import type { FakeHostWorld } from "../e2e/fakeHost";
import type { BridgeLittleState } from "../src/lib/bridge";
import { initialWorld, installFakeHost, pressAndLift, SPACE_1, SPACE_2, splitWorld, tab, treeItem } from "./support";

export interface CaptureScenario {
	name: string;
	world?: FakeHostWorld;
	colorScheme?: "light" | "dark";
	locale?: string;
	run: (page: Page) => Promise<void>;
}

// Deterministic chrome-UI scenarios for PR-review media. Each one runs against the fake host,
// so the output only changes when the interface does.
const idle = async () => {};
const sidebarAt = (sidebarWidth: number): FakeHostWorld => ({ ...initialWorld(), sidebarWidth });

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
];

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

// Settings > Agents with agent control on, scrolled to the agent access switches.
const agentAccessWorld = (): FakeHostWorld => ({ ...initialWorld(), settings: { agentControlEnabled: "true" } });

async function agentAccessSettings(page: Page) {
	await page.evaluate(() => window.__lilo!.receive({ event: "openSettings" }));
	await page.locator(".section-nav-button").filter({ hasText: "Agents" }).click();
	await page.locator("[data-setting-id='agentControl']").scrollIntoViewIfNeeded();
}

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
	{ name: "settings-agent-access-light", world: agentAccessWorld(), run: agentAccessSettings },
	{ name: "settings-agent-access-dark", colorScheme: "dark", world: agentAccessWorld(), run: agentAccessSettings },
);
