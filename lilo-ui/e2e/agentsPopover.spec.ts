import { expect, test, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";

// Three external MCP clients in the three states the cockpit cares about: acting on a tab, waiting
// on the user, and connected with nothing yet to show.
async function connectMcpClients(page: Page) {
	await page.evaluate(() => {
		window.__lilo!.receive({ event: "settingsLoaded", settings: { agentsEnabled: "true" } });
		window.__lilo!.receive({
			event: "agentClientsLoaded",
			clients: [{ id: "claudeCode", configured: true, icon: null }],
			allowed: [
				{ name: "claude-code", displayName: "Claude Code", lastSeen: null, client: "claudeCode" },
				{ name: "research-bot", displayName: "research-bot", lastSeen: null, client: null },
			],
			permissions: {},
		});
	});
	await page.evaluate(([spaceId]) => window.__lilo!.receive({
		event: "agentActivity",
		moods: {},
		clients: [
			{ name: "claude-code", busy: true, actingTabIds: ["tab-alpha"], spaceIds: [spaceId], waitingForUser: false },
			{ name: "research-bot", busy: false, actingTabIds: [], spaceIds: [spaceId], waitingForUser: true },
			{ name: "quiet-script", busy: false, actingTabIds: [], spaceIds: [], waitingForUser: false },
		],
		agentsSpaceIds: [],
		agentsProfileId: "",
		hiddenAgentsSpaceIds: [],
	}), [SPACE_1]);
}

test("the Agents popover lists connected MCP clients apart from conversations, with their state and space", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await connectMcpClients(page);

	await page.locator(".agents-button").first().click();
	const popover = page.locator(".float-popover");
	await expect(popover).toBeVisible();
	await expect(popover.locator(".section-label")).toHaveText(["MCP clients"]);

	const row = (name: string) => popover.locator(".item", { has: page.getByText(name, { exact: true }) });
	await expect(row("Claude Code").locator(".detail")).toHaveText("Working");
	await expect(row("Claude Code").locator(".space")).toHaveText("Work");
	await expect(row("research-bot").locator(".detail")).toHaveText("Waiting for you");
	await expect(row("quiet-script").locator(".detail")).toHaveText("Connected");
});

test("revealing an acting MCP client's tab closes the popover and shows that tab", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await connectMcpClients(page);

	await page.locator(".agents-button").first().click();
	await page.getByRole("button", { name: /Claude Code, Working, Work/ }).click();

	await expect(page.locator(".float-popover")).toHaveCount(0);
	const revealed = (await sentCommands(page)).filter((command) => command.action === "revealTerminal");
	expect(revealed.at(-1)?.payload).toEqual({ tabId: "tab-alpha" });
});

test("revealing an MCP client with no acting tab switches to its Agents space", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await connectMcpClients(page);

	await page.locator(".agents-button").first().click();
	await page.getByRole("button", { name: /research-bot, Waiting for you, Work/ }).click();

	const switched = (await sentCommands(page)).filter((command) => command.action === "switchSpace");
	expect(switched.at(-1)?.payload).toMatchObject({ id: SPACE_1 });
});

test("an MCP client connected to no space yet has nothing to reveal", async ({ page }) => {
	await bootChrome(page, initialWorld());
	await connectMcpClients(page);

	await page.locator(".agents-button").first().click();
	const quiet = page.locator(".float-popover .item", { has: page.getByText("quiet-script", { exact: true }) });
	await expect(quiet.locator("button.float-row")).toHaveCount(0);
	await expect(quiet.locator("div.float-row.static")).toHaveCount(1);
});
