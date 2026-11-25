// The shared contract cases, run against the TypeScript schema: the Swift host runs the same
// file (LiloTests/Companion/CompanionHostTests.swift), so a divergence between the two
// validators fails on both sides instead of at runtime in a browser.
import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseRequest } from "./protocol.ts";

interface ContractCase {
	name: string;
	message: unknown;
	error?: string;
}

const fixtures = JSON.parse(
	readFileSync(new URL("./protocol.fixtures.json", import.meta.url), "utf8"),
) as { cases: ContractCase[] };

describe("shared contract cases", () => {
	for (const contract of fixtures.cases) {
		test(contract.name, () => {
			const parsed = parseRequest(contract.message);
			if (contract.error === undefined) {
				assert.ok(!("error" in parsed), `expected acceptance, got ${JSON.stringify(parsed)}`);
				return;
			}
			assert.ok("error" in parsed, "expected a rejection");
			assert.equal(parsed.error, contract.error);
		});
	}
});
