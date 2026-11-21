import { expect, test, type Page } from "@playwright/test";
import { bootChrome } from "./fakeHost";
import { initialWorld, SPACE_1 } from "./fixtures";
import type { BridgeTabSnapshot } from "../src/lib/bridge/protocol";

function setSleeping(page: Page, tab: BridgeTabSnapshot, isSleeping: boolean): Promise<void> {
	return page.evaluate((m) => window.__lilo!.receive(m as never), {
		event: "browserStatePatch",
		operations: [{ kind: "tabUpdated", spaceId: tab.spaceId, tab: { ...tab, isSleeping } }],
	});
}

for (const colorScheme of ["light", "dark"] as const) {
	test(`a sleeping tab is dimmed, ringed and labelled, then clears on wake in ${colorScheme} mode`, async ({ page }) => {
		await page.emulateMedia({ colorScheme });
		const world = initialWorld();
		await bootChrome(page, world);
		const tab = world.tabsBySpace[SPACE_1][1];
		const row = page.locator(`.tab-item[data-tab-id="${tab.id}"]`);
		await expect(row.locator(".doze-ring")).toHaveCount(0);
		await expect(row).toHaveAccessibleName("Beta Mail");

		await setSleeping(page, tab, true);
		await expect(row).toHaveClass(/dozing/);
		await expect(row.locator(".doze-ring")).toHaveCount(1);
		await expect(row).toHaveAccessibleName("Beta Mail, Sleeping");
		await expect(row.locator(".doze-ring")).toHaveCSS("border-top-style", "dotted");

		// The title keeps full opacity, so its contrast is the secondary text color's.
		await expect(row.locator(".tab-title")).toHaveCSS("opacity", "1");

		await setSleeping(page, tab, false);
		await expect(row).not.toHaveClass(/dozing/);
		await expect(row.locator(".doze-ring")).toHaveCount(0);
		await expect(row).toHaveAccessibleName("Beta Mail");
	});
}
