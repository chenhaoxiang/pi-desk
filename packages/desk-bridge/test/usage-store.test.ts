import test from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, readdir, stat, writeFile, mkdir, symlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { usageEntry, UsageWriter, validUsage } from "../src/usage-store.ts";
import type { Identity } from "../src/protocol.ts";
const identity: Identity = { localHostId: "fixture-host", nativeSessionId: "a", runtimeEpoch: "one" };
const now = Date.now();
const message = (timestamp = 1710053940000) => ({ role: "assistant", timestamp, provider: "fixture", model: "alpha", stopReason: "stop", usage: { input: 100, output: 20, cacheRead: 30, cacheWrite: 5, reasoning: 10, cacheWrite1h: 3, cost: { total: 100 } }, content: [{ text: "PRIVATE_CONTENT_NOT_TO_KEEP" }] });
async function root() { await mkdir(resolve("tmp/usage-store-tests"), { recursive: true }); return mkdtemp(resolve("tmp/usage-store-tests/case-")); }
async function records(root: string) {
  const out: unknown[] = [];
  for (const shard of await readdir(join(root, "spool")).catch(() => []))
    for (const file of await readdir(join(root, "spool", shard))) out.push(JSON.parse(await readFile(join(root, "spool", shard, file), "utf8")));
  return out;
}
test("usage final projection is scalar-only, original UTC time, stable across reload, and excludes subsets", () => {
  const a = usageEntry(identity, "receipt-1", message(), now)!;
  const b = usageEntry({ ...identity, runtimeEpoch: "two" }, "receipt-1", message(), now)!;
  assert.deepEqual(a, b);
  assert.equal(a.occurredAt, 1710053940000);
  assert.deepEqual(a.tokens, { input: 100, output: 20, cacheRead: 30, cacheWrite: 5 });
  assert.ok(!JSON.stringify(a).includes("PRIVATE"));
  assert.equal(usageEntry(identity, "receipt-1", message(now + 100000), now), undefined);
  assert.equal(usageEntry(identity, "receipt-1", { ...message(), stopReason: "pending" }, now), undefined);
  assert.equal(usageEntry(identity, "receipt-1", { ...message(), stopReason: "deferred" }, now), undefined);
  assert.equal(validUsage({ ...a, prompt: "no" }), false);
  assert.equal(validUsage({ ...a, tokens: { ...a.tokens, input: NaN } }), false);
});
test("UI-independent private atomic spool survives reload and concurrent duplicate writers", async () => {
  const dir = await root();
  const a = new UsageWriter(identity, { root: dir }), b = new UsageWriter({ ...identity, runtimeEpoch: "two" }, { root: dir });
  const entry = usageEntry(identity, "receipt-1", message(), now)!;
  assert.equal(a.enqueue(entry), true); assert.equal(b.enqueue(entry), true);
  await Promise.all([a.flush(), b.flush()]);
  assert.deepEqual(await records(dir), [entry]);
  const mode = await stat(join(dir, "spool", entry.id.slice(0, 2), entry.id + ".json"));
  assert.equal(mode.mode & 0o077, 0); assert.equal(mode.nlink, 1);
  a.close(); b.close(); await Promise.all([a.flush(), b.flush()]);
});
test("same receipt conflict preserves first bytes; missing fields remain null", async () => {
  const dir = await root(); const writer = new UsageWriter(identity, { root: dir });
  const entry = usageEntry(identity, "receipt-1", message(), now)!;
  writer.enqueue(entry); await writer.flush();
  writer.enqueue({ ...entry, tokens: { ...entry.tokens, input: 999 } }); await writer.flush();
  assert.deepEqual(await records(dir), [entry]);
  assert.ok(writer.status().reasons.includes("receipt-conflict"));
  const incomplete = usageEntry(identity, "receipt-2", { ...message(), usage: { input: 7 } }, now)!;
  assert.deepEqual(incomplete.tokens, { input: 7, output: null, cacheRead: null, cacheWrite: null });
  writer.close(); await writer.flush();
});
test("bounded enqueue never awaits failed storage; pending/failure/drop is explicit and recovery works", async () => {
  const dir = await root(); let fails = true, calls = 0;
  const writer = new UsageWriter(identity, { root: dir, maximumQueue: 2, write: async () => { calls++; if (fails) throw Error("ENOSPC"); } });
  const entry = usageEntry(identity, "receipt-1", message(), now)!;
  assert.equal(writer.enqueue(entry), true); assert.equal(calls, 0);
  assert.equal(writer.enqueue({ ...entry, id: "a".repeat(64) }), true);
  assert.equal(writer.enqueue({ ...entry, id: "b".repeat(64) }), false);
  await writer.flush();
  assert.equal(writer.status().pending, 2); assert.equal(writer.status().dropped, 1);
  assert.ok(writer.status().writeFailures > 0);
  fails = false; await writer.flush(); assert.equal(writer.status().pending, 0);
  writer.close(); await writer.flush();
});
test("closed writers bound permanent failure retries while a live host continues", async () => {
  const dir = await root(); let writes = 0;
  const writer = new UsageWriter(identity, { root: dir, write: async () => { writes++; throw Error("ENOSPC"); } });
  writer.enqueue(usageEntry(identity, "close-failure", message(), now)!);
  await writer.flush();
  const beforeClose = writer.status().writeFailures;
  writer.close();
  for (let i = 0; i < 8; i++) await writer.flush();
  assert.ok(writer.status().writeFailures <= beforeClose + 3);
  assert.ok(writer.status().reasons.includes("close-flush-unconfirmed"));
  assert.equal(writer.status().pending, 1, "unconfirmed data must not be reported as persisted");
  const stopped = writes;
  await new Promise(resolve => setTimeout(resolve, 1150));
  assert.equal(writes, stopped, "a closed runtime must release its retry timer");
});

test("normal close drains every bounded batch and persists closed recorder state", async () => {
  const dir = await root(); let accepted = 0;
  const writer = new UsageWriter(identity, { root: dir, write: async () => { accepted++; } });
  for (let i = 0; i < 100; i++) writer.enqueue(usageEntry(identity, "close-batch-" + i, message(), now)!);
  writer.close();
  let state: { closed: boolean; pending: number; accepted: number } | undefined;
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const names = await readdir(join(dir, "recorders")).catch(() => []);
    if (names[0]) state = JSON.parse(await readFile(join(dir, "recorders", names[0]), "utf8"));
    if (state?.closed && state.pending === 0 && state.accepted === 100) break;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.equal(accepted, 100); assert.equal(writer.status().pending, 0);
  assert.equal(state?.closed, true); assert.equal(state?.pending, 0); assert.equal(state?.accepted, 100);
  assert.ok(!writer.status().reasons.includes("close-flush-unconfirmed"));
});

test("new persistent recorder does not stop after the old 4096 attachment receipt cap", async () => {
  const dir = await root(); let count = 0;
  const writer = new UsageWriter(identity, { root: dir, maximumQueue: 64, write: async () => { count++; } });
  for (let i = 0; i < 4200; i += 20) {
    for (let j = i; j < Math.min(i + 20, 4200); j++) writer.enqueue(usageEntry(identity, "receipt-" + j, message(), now)!);
    await writer.flush();
  }
  assert.equal(count, 4200); assert.equal(writer.status().pending, 0);
  writer.close(); await writer.flush();
});
test("usage final handler path is bounded and non-blocking on 10k events", async () => {
  const dir = await root(), times: number[] = [];
  const writer = new UsageWriter(identity, { root: dir, write: async () => {} });
  for (let i = 0; i < 10000; i++) {
    const start = performance.now();
    writer.enqueue(usageEntry(identity, "perf-" + i, message(), now)!);
    times.push(performance.now() - start);
  }
  times.sort((a, b) => a - b);
  assert.ok(times[9500] <= 1); assert.ok(times[9900] <= 5);
  assert.ok(writer.status().pending <= 256); assert.ok(writer.status().dropped > 0);
  while (writer.status().pending > 0) await writer.flush();
  writer.close(); await writer.flush();
  console.log(JSON.stringify({ usageHandlerEvents: 10000, p95ms: times[9500], p99ms: times[9900], realProviderCalls: 0 }));
});
test("shared time golden keeps two sessions, replay, child/tool boundaries distinct", async () => {
  const fixture = JSON.parse(await readFile(resolve("Fixtures/usage-time-v1.json"), "utf8"));
  const dir = await root(); const writer = new UsageWriter(identity, { root: dir });
  for (const row of fixture.records) {
    const [provider, model] = row.model.split("/");
    writer.enqueue(usageEntry({ ...identity, nativeSessionId: row.session }, row.receipt, { ...message(row.timestamp), provider, model, usage: row.tokens }, now)!);
  }
  await writer.flush();
  const entries = await records(dir) as ReturnType<typeof usageEntry>[];
  assert.equal(entries.length, fixture.expected.uniqueRecords);
  for (const key of ["input", "output", "cacheRead", "cacheWrite"] as const) assert.equal(entries.reduce((sum, e) => sum + (e!.tokens[key] ?? 0), 0), fixture.expected[key]);
  assert.ok(!JSON.stringify(entries).includes("999"));
  writer.close(); await writer.flush();
});
