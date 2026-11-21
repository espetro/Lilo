import { mkdirSync, renameSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { test } from "@playwright/test";

import { scenarios } from "./scenarios";
import { bootChrome, initialWorld } from "./support";

// The output lives outside lilo-ui/, next to the other build outputs, so the harness never
// writes into the source tree. CAPTURE_OUT may be absolute.
const root = resolve(fileURLToPath(new URL(".", import.meta.url)), "../..");
const outDir = resolve(root, process.env.CAPTURE_OUT ?? "build/captures");

for (const scenario of scenarios) {
	test(`capture ${scenario.name}`, async ({ browser }, testInfo) => {
		const browserDir = `${outDir}/${testInfo.project.name}`;
		mkdirSync(browserDir, { recursive: true });
		const viewport = scenario.viewport ?? { width: 1280, height: 800 };
		const context = await browser.newContext({
			viewport,
			deviceScaleFactor: 2,
			colorScheme: scenario.colorScheme ?? "light",
			locale: scenario.locale ?? "en-US",
			recordVideo: { dir: browserDir, size: viewport },
		});
		const page = await context.newPage();
		await (scenario.boot ?? bootChrome)(page, scenario.world ?? initialWorld());
		await scenario.run(page);
		await page.screenshot({ path: `${browserDir}/${scenario.name}.png` });
		const video = page.video();
		// Closing the context flushes the recording; Playwright names it after a random id.
		await context.close();
		if (video) renameSync(await video.path(), `${browserDir}/${scenario.name}.webm`);
	});
}
