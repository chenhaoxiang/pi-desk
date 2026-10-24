import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { performance } from "node:perf_hooks";
import { ActionRouter } from "../src/actions.ts";
import { OwnerRPC } from "../src/owners.ts";
import { BridgeTransport } from "../src/transport.ts";
import { AttachmentUsage } from "../src/usage.ts";
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { Snapshot, RecordV1 } from "../src/protocol.ts";
const wait = () => new Promise((r) => setTimeout(r, 20));
const fixture = JSON.parse(
	await readFile(
		new URL("../../../Fixtures/wire-v1.json", import.meta.url),
		"utf8",
	),
) as RecordV1;
test("bounded duplicate admission retains receipt, conflicts and expired requests do not dispatch", async () => {
	let calls = 0;
	let now = Date.now();
	const events = { on: () => () => {}, emit: () => {} };
	const rpc = new OwnerRPC(events as ExtensionAPI["events"], "fixture", 10);
	const router = new ActionRouter(
		{
			sendUserMessage: () => {
				calls++;
			},
		},
		() => ({ abort() {} }) as ExtensionContext,
		() => fixture.snapshot!,
		rpc,
		rpc,
		() => now,
	);
	const action: RecordV1 = {
		version: 1,
		kind: "action",
		identity: fixture.identity,
		issuedAt: now,
		requestId: "one",
		action: "session.message",
		target: { owner: "pi" },
		parameters: { text: "fixture", mode: "followUp" },
	};
	const first = router.handle(action);
	const duplicate = router.handle(action);
	await wait();
	assert.equal((await first).status, "requested");
	assert.deepEqual(await duplicate, await first);
	assert.equal(calls, 1);
	assert.equal(
		(
			await router.handle({
				...action,
				parameters: { text: "changed", mode: "followUp" },
			})
		).code,
		"request-id-conflict",
	);
	now += 31_000;
	assert.equal(
		(await router.handle({ ...action, requestId: "late" })).status,
		"unknown",
	);
	assert.equal(calls, 1);
	router.close();
	assert.equal(
		(await router.handle({ ...action, requestId: "closed" })).code,
		"stale-epoch",
	);
	rpc.close();
});
test("offline/slow transport coalesces bounded records; saturating replies never blocks production", () => {
	const t = new BridgeTransport(
		"/fixture/unavailable",
		"/fixture/helper",
		() => fixture,
		() => {},
	);
	for (let i = 0; i < 100_000; i++) t.publish({ ...fixture, kind: "snapshot" });
	assert.equal(t.queuedRecords, 1);
	assert.equal(t.dropped, 99_999);
	for (let i = 0; i < 10_000; i++)
		t.reply({
			...fixture,
			kind: "action-result",
			snapshot: undefined,
			requestId: "reply-" + i,
			result: { status: "requested", code: "fixture" },
		});
	assert.ok(t.queuedRecords <= 33);
	t.close();
	assert.equal(t.queuedRecords, 0);
});
test("settled receipt cap is a lower bound, not an LRU that double bills", () => {
	const u = new AttachmentUsage("window", 1, 2);
	const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 };
	u.settle("a", usage);
	u.settle("b", usage);
	u.settle("c", usage);
	u.settle("a", usage);
	assert.equal(u.report().tokens.input, 2);
	assert.ok(u.report().reasons.includes("receipt-window-full"));
	u.settle(undefined, usage);
	assert.ok(u.report().reasons.includes("missing-receipt"));
});
test("white-list producer synchronous budget on 10k metadata events", async () => {
	const { registerBridge } = await import("../src/index.ts");
	const handlers = new Map<string, Function>();
	const times: number[] = [];
	const ctx = {
		cwd: "/fixture",
		mode: "rpc",
		model: undefined,
		sessionManager: { getSessionId: () => "perf-session" },
		isIdle: () => true,
		hasPendingMessages: () => false,
	} as unknown as ExtensionContext;
	const pi = {
		on: (n: string, f: Function) => {
			handlers.set(n, f);
			return () => {};
		},
		events: { on: () => () => {}, emit: () => {} },
		getSessionName: () => "perf",
		getThinkingLevel: () => "high",
	} as unknown as ExtensionAPI;
	registerBridge(pi, {
		transport: () => ({
			start() {},
			publish() {},
			reply() {},
			close() {},
			dropped: 0,
		}),
	});
	handlers.get("session_start")!({}, ctx);
	for (let i = 0; i < 10000; i++) {
		const start = performance.now();
		const result = handlers.get("tool_execution_start")!(
			{
				toolCallId: String(i % 32),
				toolName: "read",
				args: { private: "not-forwarded" },
			},
			ctx,
		);
		assert.equal(result, undefined);
		times.push(performance.now() - start);
	}
	times.sort((a, b) => a - b);
	const p95 = times[9500],
		p99 = times[9900];
	assert.ok(p95 <= 1);
	assert.ok(p99 <= 5);
	handlers.get("session_shutdown")!({}, ctx);
	console.log(
		JSON.stringify({
			events: 10000,
			handlerP95ms: p95,
			handlerP99ms: p99,
			modelCalls: 0,
			manualConfirmations: 0,
		}),
	);
});
