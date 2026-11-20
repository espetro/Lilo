import { expect, type Page } from "@playwright/test";

import type { FakeHostWorld } from "../e2e/fakeHost";
import { SPACE_2 } from "./support";

export interface CaptureScenario {
	name: string;
	world?: FakeHostWorld;
	colorScheme?: "light" | "dark";
	locale?: string;
	run: (page: Page) => Promise<void>;
}

// Deterministic chrome-UI scenarios for PR-review media. Each one runs against the fake host,
// so the output only changes when the interface does.
export const scenarios: CaptureScenario[] = [
	{
		name: "sidebar-spaces",
		run: async (page: Page) => {
			await page.locator(`[data-space-dnd-id="${SPACE_2}"] .space-icon-btn`).click();
			await expect(page.locator('.space-pane [data-tab-id="tab-zeta"]')).toHaveCount(1);
		},
	},
	{
		name: "command-bar",
		run: async (page: Page) => {
			await page.evaluate(() => window.__lilo!.receive({ event: "openCommandBar" }));
			const input = page.locator(".command-bar-input");
			await input.pressSequentially("beta");
			await expect(page.locator(".command-bar-result.selected")).toContainText("Beta Mail");
			await input.press("Enter");
			await expect(page.locator(".command-bar")).toBeHidden();
		},
	},
];
