import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { test } from "@playwright/test";

import { scenarios } from "./scenarios";
import { bootChrome, initialWorld } from "./support";

// The output lives outside lilo-ui/, next to the other build outputs, so the harness never
// writes into the source tree.
const root = fileURLToPath(new URL("../../", import.meta.url));
const outDir = `${root}/${process.env.CAPTURE_OUT ?? "build/captures"}`;

for (const scenario of scenarios) {
	test(`capture ${scenario.name}`, async ({ browser }, testInfo) => {
		const browserDir = `${outDir}/${testInfo.project.name}`;
		mkdirSync(browserDir, { recursive: true });
		const context = await browser.newContext({
			viewport: { width: 1280, height: 800 },
			deviceScaleFactor: 2,
			colorScheme: scenario.colorScheme ?? "light",
			locale: scenario.locale ?? "en-US",
			recordVideo: { dir: browserDir, size: { width: 1280, height: 800 } },
		});
		const page = await context.newPage();
		await bootChrome(page, scenario.world ?? initialWorld());
		await scenario.run(page);
		await page.screenshot({ path: `${browserDir}/${scenario.name}.png` });
		// Closing the context flushes the recorded video.
		await context.close();
	});
}
