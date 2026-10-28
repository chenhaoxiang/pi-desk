import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, writeFile, readFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createHost, ai, until, sdkRoot, sdk } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
const withTUI = process.argv.includes("--tui");
if (withTUI) assert.ok(process.stdin.isTTY && process.stdout.isTTY && process.env.PI_OFFLINE === "1", "TUI soak requires owned PTY and offline mode");
const seconds = Number(process.env.PI_DESK_SOAK_SECONDS ?? 600);
assert.ok(Number.isInteger(seconds) && seconds >= 600 && seconds <= 900, "soak is bounded to 10–15 minutes");
await mkdir("tmp/lifecycle-soak", { recursive: true });
const root = await mkdtemp(resolve("tmp/lifecycle-soak/case-"));
// Keep the UDS path short without leaving the target repository.
process.env.PI_DESK_SOCKET = join(root, "desk.sock");
process.env.PI_DESK_PEER_CHECK = resolve(".build/debug/PiDeskPeerCheck");
const records = [];
let receiver, serverGeneration = 0, receiverRestarts = 0, offlineRounds = 0, iterations = 0;
let toolRelease, toolStarted = false, peakRSS = 0;
const hosts = [], startedAt = Date.now();
let interactive, tuiRuntime;
const traces = { agent_start: 0, agent_end: 0, agent_settled: 0, tool_execution_end: 0 };
async function startReceiver() {
  const generation = ++serverGeneration;
  receiver = spawn(resolve(".build/debug/PiDeskTransportTests"), ["--serve", process.env.PI_DESK_SOCKET], { stdio: ["pipe", "pipe", "pipe"] });
  let carry = "", ready = false, diagnostic = "";
  receiver.stdout.on("data", bytes => {
    carry += String(bytes);
    while (carry.includes("\n")) {
      const i = carry.indexOf("\n"), line = carry.slice(0, i); carry = carry.slice(i + 1);
      const value = JSON.parse(line);
      if (value.event === "socket-ready") ready = true;
      if (value.event === "record") { records.push({ generation, record: value.record }); if (records.length > 512) records.shift(); }
    }
  });
  receiver.stderr.on("data", b => { diagnostic = (diagnostic + String(b)).slice(-1024); });
  await until(() => ready || receiver.exitCode !== null, 8000);
  assert.equal(ready, true, "owned Swift receiver failed: " + diagnostic);
}
async function stopReceiver() {
  if (!receiver || receiver.exitCode !== null || receiver.signalCode !== null) return;
  const child = receiver; child.kill("SIGKILL"); await once(child, "exit");
}
async function storedCount() {
  const spool = join(root, "usage-v1/spool"); let count = 0;
  for (const shard of await readdir(spool).catch(() => [])) {
    if (!/^[a-f0-9]{2}$/.test(shard)) continue;
    count += (await readdir(join(spool, shard))).filter(f => /^[a-f0-9]{64}\.json$/.test(f)).length;
  }
  return count;
}
async function status(final = false, error = undefined) {
  const result = { ok: final && !error, final, startedAt, elapsedSeconds: (Date.now() - startedAt) / 1000,
    scope: withTUI ? "actual-interactive-mode-pty-and-native-sdk" : "native-sdk-isolated-faux-soak-not-interactive-tui", sdkRoot, root,
    actualInteractiveMode: withTUI, processHasPTY: !!process.stdin.isTTY, tuiSnapshotObserved: records.some(r => r.record.snapshot?.display.mode === "tui"),
    iterations, receiverRestarts, offlineRounds, calls: hosts.map(h => h.faux.state.callCount),
    storedFinalRecords: await storedCount(), traces, peakRSS, realProviderCalls: 0, addedConfirmations: 0,
    errors: hosts.flatMap(h => h.errors), failure: error ? String(error.message ?? error) : undefined };
  await writeFile(join(root, "status.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
  if (final) {
    if (process.env.PI_DESK_TUI_RESULT) await writeFile(process.env.PI_DESK_TUI_RESULT, JSON.stringify(result, null, 2), { mode: 0o600 });
    console.log(JSON.stringify(result));
  }
}
try {
  await startReceiver();
  const tools = [{ name: "soak_hold", label: "Synthetic soak hold", description: "Owned deterministic lifecycle fixture", parameters: { type: "object", properties: {}, additionalProperties: false }, execute: async () => { toolStarted = true; await new Promise(r => { toolRelease = r; }); return { content: [{ type: "text", text: "SYNTHETIC_TOOL_OK" }], details: {} }; } }];
  for (const name of ["A", "B"]) {
    const h = await createHost(root, name, { bridge: registerBridge, tools }); hosts.push(h);
    h.session.setActiveToolsByName(["soak_hold"]);
    h.session.subscribe(e => { if (e.type in traces) traces[e.type]++; });
  }
  await until(() => new Set(records.map(r => r.record.identity.nativeSessionId)).size === 2, 10000);
  if (withTUI) {
    tuiRuntime = new sdk.AgentSessionRuntime(hosts[0].session, hosts[0].services, async () => { throw Error("fixture-does-not-replace-session"); });
    interactive = new sdk.InteractiveMode(tuiRuntime, { verbose: false, tuiMode: "inline" });
    await interactive.init();
    await until(() => records.some(r => r.record.snapshot?.display.mode === "tui"), 10000);
  }
  const loadouts = hosts.map(h => ({ model: h.session.model.id, effort: h.session.thinkingLevel, tools: h.session.getActiveToolNames(), prompt: h.session.systemPrompt }));
  const deadline = startedAt + seconds * 1000;
  while (Date.now() < deadline) {
    iterations++;
    if (iterations % 12 === 4) await stopReceiver();
    const offline = receiver.exitCode !== null || receiver.signalCode !== null;
    if (offline) offlineRounds++;
    const [a, b] = hosts;
    b.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_B_OK")]);
    if (iterations % 5 === 1) {
      toolStarted = false;
      a.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("soak_hold", {}), { stopReason: "toolUse" }), ai.fauxAssistantMessage("SYNTHETIC_TOOL_CONTINUE"), ai.fauxAssistantMessage("SYNTHETIC_FOLLOWUP_DONE")]);
      const work = a.session.prompt("synthetic lifecycle tool");
      await until(() => toolStarted);
      a.api.sendUserMessage("synthetic queued continuation", { deliverAs: "followUp" });
      await until(() => a.session.getFollowUpMessages().length === 1);
      toolRelease(); await work;
      assert.equal(a.session.getLastAssistantText(), "SYNTHETIC_FOLLOWUP_DONE");
    } else {
      a.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_A_OK")]); await a.session.prompt("synthetic lifecycle turn");
    }
    await b.session.prompt("synthetic independent turn");
    assert.deepEqual(hosts.map(h => ({ model: h.session.model.id, effort: h.session.thinkingLevel, tools: h.session.getActiveToolNames(), prompt: h.session.systemPrompt })), loadouts);
    assert.ok(hosts.every(h => h.errors.length === 0));
    if (iterations % 12 === 6) {
      const before = hosts.map(h => h.faux.state.callCount);
      await startReceiver(); receiverRestarts++;
      await until(() => new Set(records.filter(r => r.generation === serverGeneration && r.record.kind === "hello").map(r => r.record.identity.nativeSessionId)).size === 2, 15000);
      assert.deepEqual(hosts.map(h => h.faux.state.callCount), before, "reconnect must not replay a model turn");
    }
    peakRSS = Math.max(peakRSS, process.memoryUsage().rss);
    await status();
    await new Promise(r => setTimeout(r, Math.min(10000, Math.max(1, deadline - Date.now()))));
  }
  const finalCalls = hosts.reduce((n, h) => n + h.faux.state.callCount, 0);
  await until(async () => await storedCount() === finalCalls, 15000);
  assert.ok(iterations >= 30 && offlineRounds >= 3 && receiverRestarts >= 1);
  assert.ok(traces.agent_settled >= iterations * 2 && traces.tool_execution_end > 0);
  await status(true);
} catch (error) { await status(true, error); process.exitCode = 1; }
finally {
  if (toolRelease) toolRelease();
  interactive?.stop();
  for (const h of hosts) await h.close();
  if (tuiRuntime) await tuiRuntime.dispose();
  await stopReceiver();
  if (withTUI) process.exit(process.exitCode ?? 0);
}
