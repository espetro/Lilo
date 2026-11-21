#!/usr/bin/env node
// Converts the capture harness's webm recordings into mp4 and gif for PR descriptions.
// Usage: to-media.mjs [outDir], default build/captures from the repo root.
import { execFileSync } from "node:child_process";
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

const outDir = process.argv[2] ?? "build/captures";
const videos = [];

function walk(dir) {
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);
		if (entry.isDirectory()) walk(path);
		else if (entry.name.endsWith(".webm")) videos.push(path);
	}
}

try {
	walk(outDir);
} catch {
	console.error(`No capture output at ${outDir}`);
	process.exit(1);
}

let ffmpeg;
try {
	ffmpeg = execFileSync("which", ["ffmpeg"], { encoding: "utf8" }).trim();
} catch {
	console.error("skipped: ffmpeg not found (brew install ffmpeg / apt install ffmpeg)");
	process.exit(0);
}

for (const video of videos) {
	const base = video.replace(/\.webm$/, "");
	const palette = `${base}-palette.png`;
	execFileSync(ffmpeg, ["-y", "-loglevel", "error", "-i", video, "-c:v", "libx264", "-pix_fmt", "yuv420p", `${base}.mp4`]);
	execFileSync(ffmpeg, ["-y", "-loglevel", "error", "-i", video, "-vf", "fps=10,scale=960:-1:flags=lanczos,palettegen", palette]);
	execFileSync(ffmpeg, ["-y", "-loglevel", "error", "-i", video, "-i", palette, "-lavfi", "fps=10,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse", `${base}.gif`]);
	rmSync(palette);
	process.stdout.write(`${base}.mp4, ${base}.gif\n`);
}
