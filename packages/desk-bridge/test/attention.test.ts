import test from "node:test";
import assert from "node:assert/strict";
import { DeskSession } from "../src/session.ts";
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { RecordV1 } from "../src/protocol.ts";
const wait = () => new Promise((r) => setTimeout(r, 15));
test("actual question lifecycle only; dismiss/transport are not answer or execution authority", async () => {
	const listeners = new Map<string, (r: unknown) => void>();
	const records: RecordV1[] = [];
	const pi = {
		events: {
			on: (name: string, f: (r: unknown) => void) => {
				listeners.set(name, f);
				return () => listeners.delete(name);
			},
			emit: () => {},
		},
		getSessionName: () => "fixture",
		getThinkingLevel: () => "off",
		sendUserMessage: () => {
			throw Error("No model call allowed");
		},
	} as unknown as ExtensionAPI;
	const ctx = {
		mode: "rpc",
		cwd: "/fixture",
		sessionManager: { getSessionId: () => "a" },
		isIdle: () => true,
		hasPendingMessages: () => false,
	} as unknown as ExtensionContext;
	const session = new DeskSession(pi, ctx, {
		transport: () => ({
			start() {},
			publish: (r) => records.push(r),
			reply: (r) => records.push(r),
			close() {},
			dropped: 0,
		}),
	});
	session.prompt(true, "custom");
	await wait();
	assert.equal(records.at(-1)?.snapshot?.inputs.length, 0);
	listeners.get("pi:input-required")!({
		version: 1,
		source: "ask_user_question",
		id: "q-1",
		phase: "start",
		question: "PRIVATE_QUESTION",
	});
	await wait();
	assert.equal(records.at(-1)?.snapshot?.inputs.length, 1);
	assert.ok(!JSON.stringify(records).includes("PRIVATE_QUESTION"));
	listeners.get("pi:input-required")!({
		version: 1,
		source: "ask_user_question",
		id: "q-1",
		phase: "end",
	});
	await wait();
	assert.equal(records.at(-1)?.snapshot?.inputs.length, 0);
	listeners.get("pi-desk:evidence:v1")!({
		version: 1,
		sessionId: "a",
		id: "ci-1",
		source: "fixture",
		category: "ci",
		status: "passed",
		head: "abcdef1234",
		nature: "advice",
		raw: "PRIVATE_PAYLOAD",
	});
	await wait();
	assert.equal(records.at(-1)?.snapshot?.evidence[0].nature, "advice");
	assert.ok(!JSON.stringify(records).includes("PRIVATE_PAYLOAD"));
	session.close();
});
