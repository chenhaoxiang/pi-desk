import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DeskSession } from "../src/session.ts";
import type { RecordV1 } from "../src/protocol.ts";

const tick = () => new Promise<void>(resolve => setTimeout(resolve, 15));
function fixture() {
  const bus = new EventEmitter(), records: RecordV1[] = [], ownerCalls: string[] = [];
  let idle = false, pending = false, broken = false, now = 1_000;
  let heartbeat!: () => RecordV1;
  const pi = {
    events: { on(name: string, handler: (r: unknown) => void) { bus.on(name, handler); return () => bus.off(name, handler); }, emit(name: string, raw: unknown) { bus.emit(name, raw); } },
    getSessionName: () => "Synthetic execution fixture", getThinkingLevel: () => "off",
  } as unknown as ExtensionAPI;
  const ctx = {
    mode: "rpc", cwd: "/fixture", sessionManager: { getSessionId: () => "execution-fixture" },
    isIdle() { if (broken) throw Error("synthetic stale context"); return idle; }, hasPendingMessages: () => pending,
  } as unknown as ExtensionContext;
  bus.on("subagents:rpc:v1:request", raw => ownerCalls.push(raw.method));
  bus.on("schedule:rpc:v1:request", raw => ownerCalls.push(raw.method));
  const session = new DeskSession(pi, ctx, {
    usageRoot: false, now: () => now, captureTerminalRoute: async () => ({ kind: "unavailable", sessionId: "execution-fixture" }),
    transport: hello => { heartbeat = hello; return { start() {}, close() {}, dropped: 0, publish: r => records.push(structuredClone(r)), reply: r => records.push(structuredClone(r)) }; },
  });
  return { session, ctx, bus, records, ownerCalls, state(options: { idle?: boolean; pending?: boolean; broken?: boolean }) { idle = options.idle ?? idle; pending = options.pending ?? pending; broken = options.broken ?? broken; now += 1_000; }, snapshot: () => structuredClone(heartbeat().snapshot!) };
}

test("startup and late attachment reconcile real native idle without waiting for another agent event", async () => {
  const f = fixture();
  try {
    f.state({ idle: true }); // session_start can still be inside the startup busy boundary.
    await tick();
    assert.equal(f.records.at(-1)?.snapshot?.execution, "settled");
    f.state({ idle: false });
    f.session.observe(f.ctx); await tick();
    assert.equal(f.records.at(-1)?.snapshot?.execution, "running");
    f.state({ idle: true });
    assert.equal(f.snapshot().execution, "settled", "the existing transport heartbeat samples public scalar truth, not a frozen constructor enum");
    assert.deepEqual(f.ownerCalls, []);
  } finally { f.session.close(); }
});

test("agent_start lifecycle evidence wins over a stale idle scalar until agent_settled", async () => {
  const f = fixture();
  try {
    f.state({ idle: true });
    f.session.lifecycle("agent_start", f.ctx);
    assert.equal(f.snapshot().execution, "running", "agent_start must not be settled by the first stale idle sample");
    assert.equal(f.snapshot().executionObservation?.source, "lifecycle");
    assert.equal(f.snapshot().executionObservation?.idle, false);
    f.session.lifecycle("agent_end", f.ctx);
    assert.equal(f.snapshot().execution, "running", "agent_end is not a completion boundary");
    f.session.lifecycle("agent_settled", f.ctx);
    assert.equal(f.snapshot().execution, "settled");
    assert.equal(f.snapshot().executionObservation?.idle, true);
  } finally { f.session.close(); }
});

test("execution freshness is separate from transport heartbeat and unavailable context does not invent new proof", () => {
  const f = fixture();
  try {
    const first = f.snapshot() as any;
    assert.deepEqual(first.executionObservation, { version: 1, observedAt: first.observedAt, source: "ctx.isIdle", idle: false });
    f.state({ idle: true });
    const sampled = f.snapshot() as any;
    assert.equal(sampled.executionObservation.idle, true);
    f.state({ broken: true });
    const unavailable = f.snapshot() as any;
    assert.ok(unavailable.observedAt > sampled.observedAt);
    assert.equal(unavailable.executionObservation.observedAt, sampled.executionObservation.observedAt);
    assert.equal(unavailable.execution, "settled");
    assert.deepEqual(f.ownerCalls, []);
  } finally { f.session.close(); }
});

test("tools, queued followup, failure and abort remain consistent through cheap reconciliation", () => {
  const f = fixture();
  try {
    f.session.lifecycle("agent_start", f.ctx);
    f.session.tool(true, "call", "bash", f.ctx);
    assert.equal(f.snapshot().execution, "running");
    assert.deepEqual(f.snapshot().tools, ["bash"]);
    f.session.lifecycle("agent_end", f.ctx);
    assert.equal(f.snapshot().execution, "running", "agent_end during native recovery is not completion");
    f.state({ idle: true, pending: true });
    assert.equal(f.snapshot().pending, true);
    assert.equal(f.snapshot().execution, "running", "agent_end plus a stale idle scalar is still inside the lifecycle boundary");
    assert.deepEqual(f.snapshot().tools, ["bash"]);
    f.state({ pending: false });
    f.session.lifecycle("agent_settled", f.ctx, true);
    assert.deepEqual(f.snapshot().tools, [], "agent_settled clears orphaned tool labels");
    assert.equal(f.snapshot().execution, "aborted");
    assert.equal(f.snapshot().execution, "aborted", "heartbeats preserve the observed abort outcome");
    f.state({ idle: false }); f.session.lifecycle("agent_start", f.ctx);
    f.session.turn({ message: { role: "assistant", stopReason: "error", provider: "fixture", model: "faux", usage: {} }, toolResults: [], toolResultEntryIds: [], entries: [] } as any, f.ctx);
    f.state({ idle: true }); f.session.lifecycle("agent_settled", f.ctx);
    assert.equal(f.snapshot().execution, "failed");
    assert.equal(f.snapshot().execution, "failed", "reconciliation must not overwrite failed with settled");
  } finally { f.session.close(); }
});

test("local completion and process-terminal evidence invalidate cached running children without an owner poll", () => {
  const f = fixture();
  try {
    f.state({ idle: true });
    f.bus.emit("subagent:async-started", { id: "run-a", sessionId: "execution-fixture", agent: "worker", task: "PRIVATE_NOT_FORWARDED" });
    assert.equal(f.snapshot().execution, "waiting-children");
    f.bus.emit("subagent:async-complete", { runId: "run-a", sessionId: "other-session", state: "complete" });
    assert.equal(f.snapshot().execution, "waiting-children", "foreign session completion cannot settle this session");
    f.bus.emit("subagent:async-complete", { runId: "run-a", sessionId: "execution-fixture", state: "complete", summary: "PRIVATE_NOT_FORWARDED" });
    assert.equal(f.snapshot().execution, "settled");
    assert.equal(f.snapshot().runs[0]?.state, "complete");
    f.bus.emit("subagent:child-status", { version: 1, runId: "workflow", childRunId: "child-a", status: "started" });
    assert.equal(f.snapshot().execution, "waiting-children");
    f.bus.emit("subagent:process-terminal", { version: 1, runId: "child-a", state: "observed" });
    const ended = f.snapshot();
    assert.equal(ended.execution, "settled");
    assert.equal(ended.runs.find(r => r.runId === "child-a")?.state, "terminal");
    assert.equal(ended.runs.find(r => r.runId === "child-a")?.terminalProof, "observed");
    assert.ok(!JSON.stringify(ended).includes("PRIVATE_NOT_FORWARDED"));
    assert.deepEqual(f.ownerCalls, []);
  } finally { f.session.close(); }
});
