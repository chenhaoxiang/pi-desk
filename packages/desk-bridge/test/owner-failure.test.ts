import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
	OwnerRPC,
	ownerFailureResult,
	ownerResult,
	subagentCapabilities,
	subagentRuns,
} from "../src/owners.ts";
import { ActionRouter } from "../src/actions.ts";
import type { Snapshot, RecordV1 } from "../src/protocol.ts";
const fixture = JSON.parse(
	await readFile(
		new URL("../../../Fixtures/wire-v1.json", import.meta.url),
		"utf8",
	),
) as RecordV1;
function rpcFor(code: string, onInvoke = () => {}) {
	const bus = new EventEmitter();
	const events = {
		on: (n: string, h: (r: unknown) => void) => {
			bus.on(n, h);
			return () => {
				bus.off(n, h);
			};
		},
		emit: (n: string, r: unknown) => {
			bus.emit(n, r);
		},
	} as ExtensionAPI["events"];
	bus.on("schedule:rpc:v1:request", (request) => {
		onInvoke();
		events.emit("schedule:rpc:v1:reply:" + request.requestId, {
			version: 1,
			requestId: request.requestId,
			success: false,
			error: { code, message: "PRIVATE_ERROR_PAYLOAD" },
		});
	});
	return new OwnerRPC(events, "schedule:rpc:v1");
}
for (const code of [
	"execution_failed",
	"management-unavailable",
	"operation-outcome-unknown",
	"unexpected_PRIVATE_CODE",
]) {
	test("ambiguous owner error stays unknown: " + code, async () => {
		const rpc = rpcFor(code);
		const error = await rpc.call("schedule.delete", { id: "plan" }).then(
			() => assert.fail("expected error"),
			(e) => e,
		);
		const result = ownerFailureResult(error, "plan");
		assert.equal(result.status, "unknown");
		assert.equal(result.ownerRef, "plan");
		assert.ok(!JSON.stringify(result).includes("PRIVATE"));
		rpc.close();
	});
}
test("owner proves non-admission without exposing its message", async () => {
	const rpc = rpcFor("request-rejected");
	const error = await rpc
		.call("schedule.resume", { id: "foreign" })
		.catch((e) => e);
	assert.deepEqual(ownerFailureResult(error, "foreign"), {
		status: "rejected",
		code: "owner-request-rejected",
		ownerRef: "foreign",
	});
	rpc.close();
});
test("mutation then failure is cached as unknown, never redispatched", async () => {
	let effects = 0;
	const rpc = rpcFor("operation-outcome-unknown", () => effects++);
	const snapshot = {
		...fixture.snapshot!,
		capabilities: {
			...fixture.snapshot!.capabilities,
			actions: ["schedule.delete"],
		},
		schedules: [
			{
				owner: "schedule-prompt",
				scheduleId: "plan",
				name: "fixture",
				state: "enabled",
				actions: ["schedule.delete"],
			},
		],
	} as Snapshot;
	const router = new ActionRouter(
		{ sendUserMessage() {} },
		() => ({ abort() {} }) as ExtensionContext,
		() => snapshot,
		rpc,
		rpc,
	);
	const action: RecordV1 = {
		version: 1,
		kind: "action",
		identity: snapshot.identity,
		requestId: "one-delete",
		issuedAt: Date.now(),
		action: "schedule.delete",
		target: { owner: "schedule-prompt", scheduleId: "plan" },
	};
	const keepAlive = setTimeout(() => {}, 1000);
	try {
		const result = await router.handle(action);
		assert.equal(result.status, "unknown");
		assert.equal(result.ownerRef, "plan");
		assert.deepEqual(await router.handle(action), result);
		assert.equal(effects, 1);
	} finally {
		clearTimeout(keepAlive);
		router.close();
		rpc.close();
	}
});
test("data-level owner errors do not imply no effect; stopped runs do not offer revival", () => {
	assert.equal(
		ownerResult({ isError: true }, "fallback", "run").status,
		"unknown",
	);
	const cap = subagentCapabilities({
		capabilities: { fleetStatus: { version: 1 }, resume: true },
	});
	const rows = subagentRuns(
		{
			asyncSnapshot: {
				runs: [
					{ id: "stopped", state: "stopped" },
					{ id: "complete", state: "complete" },
				],
			},
		},
		cap,
	);
	assert.deepEqual(rows[0].actions, []);
	assert.ok(rows[1].actions.includes("run.resume"));
});
