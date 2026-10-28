import test from "node:test";
import assert from "node:assert/strict";
import { text } from "../src/protocol.ts";
test("display projection truncates complete UTF8 scalars, not bytes or surrogate halves", () => {
	for (const limit of [0, 1, 2, 3, 4, 5, 7, 64, 128, 512])
		for (const raw of [
			"中".repeat(300),
			"🙂".repeat(200),
			"a🙂中".repeat(200),
		]) {
			const output = text(raw, limit)!;
			assert.ok(Buffer.byteLength(output) <= limit);
			assert.ok(!output.includes("\ufffd"));
			assert.ok(raw.startsWith(output));
		}
	assert.equal(text("a\n中\0🙂", 9), "a 中 ");
	assert.equal(text("\ud800"), " ");
	assert.equal(text(undefined), undefined);
});
