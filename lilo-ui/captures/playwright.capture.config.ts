import { fileURLToPath } from "node:url";

import { defineConfig, devices } from "@playwright/test";

// Its own port, beside the e2e server's 5174, so both can run at once.
const port = 5199;

export default defineConfig({
	testDir: ".",
	testMatch: "*.spec.ts",
	forbidOnly: true,
	retries: 0,
	timeout: 60_000,
	fullyParallel: false,
	workers: 1,
	use: {
		baseURL: `http://localhost:${port}`,
	},
	projects: [
		{
			name: "webkit",
			use: { ...devices["Desktop Safari"] },
		},
		{
			name: "chromium",
			// Headless Chromium hides scrollbars; the app's WebKit keeps their gutter, which the sidebar's layout counts on.
			use: { ...devices["Desktop Chrome"], launchOptions: { ignoreDefaultArgs: ["--hide-scrollbars"] } },
		},
	],
	webServer: {
		command: `pnpm exec vite dev --host localhost --port ${port} --strictPort`,
		cwd: fileURLToPath(new URL("..", import.meta.url)),
		reuseExistingServer: true,
		url: `http://localhost:${port}`,
		timeout: 60_000,
	},
});
