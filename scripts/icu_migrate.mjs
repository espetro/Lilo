#!/usr/bin/env node
// One-time codemod: convert plural objects ({"one": "{count} tab", "other": "{count} tabs"})
// in lilo-ui/src/lib/i18n/locales/*.json to ICU MessageFormat strings
// ("{count, plural, one{# tab} other{# tabs}}"). `{count}` inside a form becomes `#`;
// other placeholders stay arguments. The `native` namespace is skipped: its printf strings
// feed generate_native_strings.py and are not ICU. Replacement is surgical on the raw text
// so untouched lines keep their exact formatting. Usage: node scripts/icu_migrate.mjs [--check]
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = "lilo-ui/src/lib/i18n/locales";
const files = [
	"en.json", "fr.json", "es.json", "zh-Hans.json", "pt-BR.json", "ru.json", "uk.json",
	"de.json", "ja.json", "it.json", "ko.json", "zh-Hant.json", "pl.json", "tr.json", "nl.json",
];
const PLURALS = new Set(["zero", "one", "two", "few", "many", "other"]);
// A candidate object: string keys and string values only (JSON.parse decides the rest).
const CANDIDATE = /\{\s*"(?:zero|one|two|few|many|other)"\s*:\s*"(?:[^"\\]|\\.)*"(?:\s*,\s*"\w+"\s*:\s*"(?:[^"\\]|\\.)*")*\s*\}/g;
const check = process.argv.includes("--check");

let converted = 0;
const problems = [];

for (const file of files) {
	const path = join(dir, file);
	const before = readFileSync(path, "utf8");
	// Byte range of the "native" namespace value so matches inside it can be skipped.
	const nativeStart = before.indexOf('"native"');
	const nativeObj = nativeStart === -1 ? null : before.indexOf("{", nativeStart);
	let nativeEnd = -1;
	if (nativeObj !== null && nativeObj !== -1) {
		let depth = 0;
		let i = nativeObj;
		for (; i < before.length; i++) {
			const ch = before[i];
			if (ch === '"') {
				i++;
				while (i < before.length && before[i] !== '"') i += before[i] === "\\" ? 2 : 1;
			} else if (ch === "{") depth++;
			else if (ch === "}") {
				depth--;
				if (depth === 0) break;
			}
		}
		nativeEnd = i;
	}
	const after = before.replace(CANDIDATE, (match, offset) => {
		if (nativeObj !== null && offset > nativeObj && offset < nativeEnd) return match;
		let obj;
		try {
			obj = JSON.parse(match);
		} catch {
			return match;
		}
		const keys = Object.keys(obj);
		if (!keys.length || !keys.every((k) => PLURALS.has(k))) return match;
		if (!keys.includes("other")) problems.push(`${file} @${offset}: no "other" form in ${match.slice(0, 80)}`);
		converted++;
		const options = keys.map((cat) => {
			const form = obj[cat];
			if (form.includes("#")) problems.push(`${file} @${offset}: literal # in ${JSON.stringify(form)}`);
			return `${cat}{${form.replace(/\{count\}/g, "#")}}`;
		});
		return JSON.stringify(`{count, plural, ${options.join(" ")}}`);
	});
	if (!check && after !== before) writeFileSync(path, after);
}

console.log(`${converted} plural objects converted across ${files.length} catalogs`);
for (const p of problems) console.log(`problem: ${p}`);
process.exit(problems.length ? 1 : 0);
