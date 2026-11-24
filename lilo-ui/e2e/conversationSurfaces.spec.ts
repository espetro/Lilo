import { expect, test, type Locator, type Page } from "@playwright/test";
import { bootChrome, sentCommands } from "./fakeHost";
import { initialWorld } from "./fixtures";

const agents = [
	{ id: "claude-acp", name: "Claude Agent", description: "" },
	{ id: "codex-acp", name: "Codex", description: "" },
];

function receive(page: Page, messages: Record<string, unknown>[]) {
	return page.evaluate((list) => {
		for (const message of list) window.__lilo!.receive(message as never);
	}, messages);
}

async function openAskBar(page: Page, settings: Record<string, string> = { agentsEnabled: "true" }) {
	await bootChrome(page, initialWorld());
	await receive(page, [
		{ event: "settingsLoaded", settings },
		{ event: "openAskBar", selection: "" },
		{ event: "agentCatalog", agents, projects: [], home: "/Users/example" },
	]);
	return page.locator(".ask-bar");
}

async function startConversation(page: Page, bar: ReturnType<Page["locator"]>) {
	await bar.getByRole("combobox").fill("Summarize this page");
	await bar.getByRole("button", { name: "Start" }).click();
	const start = (await sentCommands(page)).find((command) => command.action === "startConversation");
	return start?.payload as
		| { placement: string; sourceTabId: string; surfaceRequestId: string }
		| undefined;
}

// The surface lands with a scale-and-fade animation: a box measured mid-flight is a few percent
// off its resting size. Wait for the animation to finish before reading the geometry.
async function settledBox(
	locator: Locator,
): Promise<{ x: number; y: number; width: number; height: number } | null> {
	await locator.evaluate((node) =>
		Promise.all(node.getAnimations({ subtree: true }).map((animation) => animation.finished.catch(() => {}))),
	);
	return locator.boundingBox();
}

test("ask bar start opens a pending mini surface that swaps in the conversation and enlarges to its tab", async ({ page }) => {
	const bar = await openAskBar(page);
	const payload = await startConversation(page, bar);
	expect(payload).toMatchObject({ placement: "mini", sourceTabId: "tab-alpha" });
	expect(payload?.surfaceRequestId).toBeTruthy();

	const surface = page.locator(".surface.mini");
	await expect(surface).toBeVisible();
	await expect(surface).toContainText("Starting the agent...");

	await receive(page, [
		{
			event: "conversationSurfaceRequested",
			tabId: "tab-agent",
			sourceTabId: "tab-alpha",
			placement: "mini",
			surfaceRequestId: payload!.surfaceRequestId,
		},
	]);
	await expect(surface).not.toContainText("Starting the agent...");

	// Spec geometry: min(700px, content - 32px) wide, min(420px, 100% - 48px) tall, bottom-centered.
	const box = await settledBox(surface);
	const root = await page.locator(".surface-root").boundingBox();
	const expectedWidth = Math.min(700, (root?.width ?? 0) - 32);
	const expectedHeight = Math.min(420, (root?.height ?? 0) - 48);
	expect(box && Math.abs(box.width - expectedWidth)).toBeLessThan(1.5);
	expect(box && Math.abs(box.height - expectedHeight)).toBeLessThan(1.5);
	expect(box && root && Math.abs(box.x + box.width / 2 - (root.x + root.width / 2))).toBeLessThan(1);
	expect(box && root && Math.abs(box.y + box.height + 24 - (root.y + root.height))).toBeLessThan(1);

	await surface.getByRole("button", { name: "Open in a tab" }).click();
	const commands = await sentCommands(page);
	expect(commands.some((command) => command.action === "switchTab" && command.payload.id === "tab-agent")).toBe(true);
	await expect(surface).toHaveCount(0);
});

test("the placement picker changes where the next conversation opens", async ({ page }) => {
	const bar = await openAskBar(page);
	await bar.getByRole("button", { name: "Open as" }).click();
	await page.getByRole("menuitemradio", { name: "Full tab" }).click();

	const payload = await startConversation(page, bar);
	expect(payload).toMatchObject({ placement: "tab", sourceTabId: "tab-alpha" });
	// A tab start never opens a chrome surface: no pending shell waits on the native side.
	await expect(page.locator(".surface")).toHaveCount(0);
});

test("a dialog surface dismisses on Escape while pending and shows the failure briefly", async ({ page }) => {
	const bar = await openAskBar(page, { agentsEnabled: "true", agentConversationPlacement: "dialog" });
	const payload = await startConversation(page, bar);
	expect(payload).toMatchObject({ placement: "dialog" });

	const surface = page.locator(".surface.dialog");
	await expect(surface).toBeVisible();
	await expect(surface).toHaveAttribute("role", "dialog");
	// Spec geometry: min(840px, 100% - 48px) wide, min(720px, 100% - 64px, 80vh) tall, centered.
	const box = await settledBox(surface);
	const root = await page.locator(".surface-root").boundingBox();
	// The content column is narrower than the viewport, so the 840px cap loses to 100% - 48px here.
	const expectedWidth = Math.min(840, (root?.width ?? 0) - 48);
	const expectedHeight = Math.min(720, (root?.height ?? 0) - 64, (page.viewportSize()?.height ?? 0) * 0.8);
	expect(box && Math.abs(box.width - expectedWidth)).toBeLessThan(1.5);
	expect(box && Math.abs(box.height - expectedHeight)).toBeLessThan(1.5);
	expect(box && root && Math.abs(box.x + box.width / 2 - (root.x + root.width / 2))).toBeLessThan(1);
	expect(box && root && Math.abs(box.y + box.height / 2 - (root.y + root.height / 2))).toBeLessThan(1);
	await page.keyboard.press("Escape");
	await expect(surface).toHaveCount(0);

	// A failed start keeps its shell up with the error, then clears itself.
	const second = await openAskBar(page, { agentsEnabled: "true", agentConversationPlacement: "dialog" });
	const payload2 = await startConversation(page, second);
	await receive(page, [{ event: "conversationSurfaceFailed", surfaceRequestId: payload2!.surfaceRequestId, message: "No agent" }]);
	await expect(page.locator(".pending-error")).toContainText("The conversation could not be started.");
	await expect(page.locator(".surface.dialog")).toHaveCount(0, { timeout: 5000 });
});
