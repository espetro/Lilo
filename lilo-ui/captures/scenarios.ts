import { expect, type Page } from "@playwright/test";

import type { FakeHostWorld } from "../e2e/fakeHost";
import type { BridgeLittleState } from "../src/lib/bridge";
import { initialWorld, installFakeHost, SPACE_2 } from "./support";

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
