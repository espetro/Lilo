import { build } from "esbuild";

const entries = { "dist/background": "src/background.ts", "dist/content": "src/content.ts" };

await build({
	entryPoints: Object.entries(entries).map(([out, input]) => ({ out, in: input })),
	bundle: true,
	format: "esm",
	outdir: ".",
	sourcemap: false,
	logLevel: "info",
});
