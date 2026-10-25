import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { registerBridge } from "../src/index.ts";
import { AttachmentUsage, costProjection } from "../src/usage.ts";
import { type RecordV1 } from "../src/protocol.ts";
import { subagentCapabilities, subagentRuns } from "../src/owners.ts";
const wait = () => new Promise((r) => setTimeout(r, 20));
export function harness(id = "session-a") {
	const handlers = new Map<string, Function>();
	const bus = new EventEmitter();
	const wires: RecordV1[] = [];
	let receive: (r: RecordV1) => void = () => {};
	let started = 0,
		closed = 0,
		aborts = 0;
	const messages: unknown[] = [];
	const pi = new Proxy(
		{
			on: (name: string, handler: Function) => {
				handlers.set(name, handler);
				return () => handlers.delete(name);
			},
			events: {
				on: (n: string, h: (r: unknown) => void) => {
					bus.on(n, h);
					return () => {
						bus.off(n, h);
					};
				},
				emit: (n: string, r: unknown) => {
					bus.emit(n, r);
				},
			},
			getSessionName: () => "合成会话",
			getThinkingLevel: () => "high",
			sendUserMessage: (text: string, options: unknown) =>
				messages.push({ text, options }),
		},
		{
			get: (t, k) => {
				if (!(k in t)) throw Error("Forbidden host access: " + String(k));
				return t[k as keyof typeof t];
			},
		},
	) as unknown as ExtensionAPI;
	const ctx = {
		cwd: "/fixture/project",
		mode: "tui",
		hasUI: true,
		thinkingLevel: "high",
		model: { provider: "fixture", id: "faux" },
		sessionManager: { getSessionId: () => id },
		isIdle: () => true,
		hasPendingMessages: () => false,
		getContextUsage: () => undefined,
		abort: () => {
			aborts++;
		},
	} as unknown as ExtensionContext;
	const transport = () => ({
		start: () => {
			started++;
		},
		close: () => {
			closed++;
		},
		publish: (r: RecordV1) => wires.push(r),
		reply: (r: RecordV1) => wires.push(r),
		dropped: 0,
	});
	registerBridge(pi, {
		usageRoot: false,
		transport: (_hello, recv) => {
			receive = recv;
			return transport();
		},
	});
	return {
		handlers,
		bus,
		wires,
		messages,
		ctx,
		emit: (name: string, e: unknown = {}) => handlers.get(name)?.(e, ctx),
		receive: (r: RecordV1) => receive(r),
		started: () => started,
		closed: () => closed,
		aborts: () => aborts,
	};
}
test("factory starts no resources, observation never changes host loadout or blocks", async () => {
	const h = harness();
	assert.equal(h.started(), 0);
	assert.deepEqual(
		[...h.handlers.keys()],
		[
			"session_start",
			"session_shutdown",
			"agent_start",
			"agent_end",
			"agent_settled",
			"model_select",
			"tool_execution_start",
			"tool_execution_end",
			"turn_end",
			"ui_prompt_start",
			"ui_prompt_end",
		],
	);
	assert.equal(h.emit("session_start"), undefined);
	assert.equal(h.started(), 1);
	const raw = {
		toolCallId: "call-a",
		toolName: "read",
		args: { raw: "SYNTHETIC_PRIVATE_VALUE" },
	};
	const before = JSON.stringify(raw);
	assert.equal(h.emit("tool_execution_start", raw), undefined);
	assert.equal(h.emit("tool_execution_end", raw), undefined);
	assert.equal(JSON.stringify(raw), before);
	await wait();
	assert.ok(h.wires.length);
	assert.ok(!JSON.stringify(h.wires).includes("SYNTHETIC_PRIVATE_VALUE"));
	h.emit("agent_start");
	h.emit("agent_end");
	await wait();
	assert.equal(h.wires.at(-1)?.snapshot?.execution, "running");
	h.emit("session_shutdown");
	h.emit("session_shutdown");
	assert.equal(h.closed(), 1);
	assert.equal(h.aborts(), 0);
	assert.equal(h.messages.length, 0);
});
test("native management exact epoch + dedup returns requested, never queued", async () => {
	const a = harness("a"),
		b = harness("b");
	a.emit("session_start");
	b.emit("session_start");
	await wait();
	const identity = a.wires.at(-1)!.identity;
	const action: RecordV1 = {
		version: 1,
		kind: "action",
		identity,
		issuedAt: Date.now(),
		requestId: "click-1",
		action: "session.message",
		target: { owner: "pi" },
		parameters: { text: "fixture follow up", mode: "followUp" },
	};
	a.receive(action);
	a.receive(action);
	await wait();
	assert.equal(a.messages.length, 1);
	assert.equal(b.messages.length, 0);
	assert.equal(
		a.wires.filter((w) => w.kind === "action-result").at(-1)?.result?.status,
		"requested",
	);
	a.receive({ ...action, parameters: { text: "different", mode: "steer" } });
	a.receive({
		...action,
		requestId: "old",
		identity: { ...identity, runtimeEpoch: "old" },
	});
	await wait();
	assert.equal(a.messages.length, 1);
	a.receive({
		...action,
		requestId: "stop-1",
		action: "session.abort-current",
		parameters: {},
	});
	await wait();
	assert.equal(a.aborts(), 1);
	assert.equal(b.aborts(), 0);
	a.emit("session_shutdown");
	b.emit("session_shutdown");
});
test("usage replay, unknown, cache, nested, window reset and owner lower bound", () => {
	const u = new AttachmentUsage("window-a");
	const raw = { input: 100, output: 20, cacheRead: 30, cacheWrite: 5 };
	u.settle("entry-a", raw);
	u.settle("entry-a", raw);
	assert.deepEqual(u.report().tokens, raw);
	u.settle("tool-entry", { input: 3, output: 2, cacheRead: 0, cacheWrite: 0 });
	assert.equal(u.report().tokens.input, 103);
	assert.equal(new AttachmentUsage("window-b").report().tokens.input, null);
	const report = costProjection(
		{
			version: 1,
			total: raw,
			children: [
				{ runId: "run-a", usage: raw, sessionFile: "SYNTHETIC_PRIVATE_VALUE" },
			],
			unresolvedAsyncChildren: 1,
		},
		"parent",
		0,
	)!;
	assert.equal(report.coverage, "partial");
	assert.deepEqual(report.includedRunIds, ["run-a"]);
	assert.ok(!JSON.stringify(report).includes("PRIVATE"));
});
test("Fleet key is not a runId and does not unlock control", () => {
	const cap = subagentCapabilities({
		capabilities: {
			fleetStatus: { version: 1 },
			resume: true,
			nonRecoveringSteer: true,
			stop: true,
		},
	});
	const runs = subagentRuns(
		{
			fleet: {
				entries: [{ key: "opaque", agent: "fixture", goal: "PRIVATE" }],
			},
			asyncSnapshot: { runs: [{ id: "run-a", state: "running" }] },
		},
		cap,
	);
	assert.equal(runs[1].runId, undefined);
	assert.deepEqual(runs[1].actions, []);
	assert.ok(runs[0].actions.includes("run.stop"));
	assert.ok(!JSON.stringify(runs).includes("PRIVATE"));
});
