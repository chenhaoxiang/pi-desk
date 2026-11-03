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
test("optional event metadata remains bounded and old snapshots remain valid", () => {
	validate(record);
	const activity = { sequence: 3, kind: "agent-settled", at: 2000, turnStartedAt: 1000, turnEndedAt: 2000, turnEndSequence: 3 };
	const withActivity = (a: unknown) => ({ ...record, snapshot: { ...record.snapshot, activity: a } });
	validate(withActivity(activity));
	for (const bad of [
		{ ...activity, sequence: 0 }, { ...activity, kind: "PRIVATE_RAW_PAYLOAD" },
		{ ...activity, at: -1 }, { ...activity, at: 1.5 }, { ...activity, at: 9e15 },
		{ ...activity, turnEndSequence: 4 }, { ...activity, turnEndedAt: undefined },
	]) assert.throws(() => validate(withActivity(bad)), /invalid-snapshot/);
});
