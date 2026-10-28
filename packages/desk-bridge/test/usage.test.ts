import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { AttachmentUsage, costProjection } from "../src/usage.ts";
import type { Tokens } from "../src/protocol.ts";
const fixture = JSON.parse(
	await readFile(
		new URL("../../../Fixtures/usage-v1.json", import.meta.url),
		"utf8",
	),
) as {
	scenarios: {
		name: string;
		settlements: { id: string; model: string; usage: Tokens }[];
		expected: Tokens;
	}[];
};
for (const scenario of fixture.scenarios)
	test("usage golden: " + scenario.name, () => {
		const usage = new AttachmentUsage("window", 100);
		for (const e of scenario.settlements) usage.settle(e.id, e.usage, e.model);
		assert.deepEqual(usage.report().tokens, scenario.expected);
		assert.equal(usage.report().coverage, "partial");
		if (scenario.name.includes("switch-model"))
			assert.equal(usage.reports().length, 2);
	});
test("reload/fork/auxiliary scopes are not promoted to native total", () => {
	const usage = new AttachmentUsage("new-window", 200);
	for (const reason of [
		"fork-inheritance-unavailable",
		"compaction-summary-not-covered",
	])
		usage.markPartial(reason);
	assert.equal(usage.report().tokens.input, null);
	assert.equal(usage.report().scope, "attachment-window");
	assert.equal(usage.report().windowId, "new-window");
	assert.equal(usage.report().coverage, "partial");
});

test("missing child coverage is null, not an invented zero or one", () => {
	assert.equal(
		new AttachmentUsage("unknown-window").report().unresolvedChildren,
		null,
	);
	const report = costProjection(
		{
			version: 1,
			total: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 },
			children: [],
		},
		"owner",
		null,
	)!;
	assert.equal(report.unresolvedChildren, null);
	assert.equal(report.coverage, "partial");
});
