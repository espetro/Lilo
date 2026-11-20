import { expect, type Page } from "@playwright/test";

import type { FakeHostWorld } from "../e2e/fakeHost";
import { initialWorld, SPACE_2 } from "./support";

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
