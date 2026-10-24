import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
	LineFramer,
	encode,
	validate,
	type RecordV1,
} from "../src/protocol.ts";
const record = JSON.parse(
	readFileSync(
		new URL("../../../Fixtures/wire-v1.json", import.meta.url),
		"utf8",
	),
) as RecordV1;
test("shared Swift/Node fixture, unknown fields, half packet", () => {
	validate(record);
	const framed = encode(record);
	const parser = new LineFramer();
	assert.deepEqual(parser.append(framed.subarray(0, 13)), []);
	assert.equal(parser.append(framed.subarray(13))[0].snapshot?.seq, 4);
});
test("rejects malformed, oversized, UTF8 and version without raw echo", () => {
	for (const bytes of [
		Buffer.from("{}\n"),
		Buffer.alloc(65537, 32),
		Buffer.from([255, 10]),
		Buffer.from(JSON.stringify({ ...record, version: 2 }) + "\n"),
	])
		assert.throws(() => new LineFramer().append(bytes));
});
