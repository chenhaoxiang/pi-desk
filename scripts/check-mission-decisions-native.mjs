import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { createHost, until, bindFixturePeerImports, ai, sdkRoot } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";

// Default: frozen contract fixture over actual SDK events. Opt-in package path:
// real native management/store, never launches a child or calls a real provider.
const native = process.env.PI_DESK_SUBAGENTS;
const bridgeEntry = process.env.PI_DESK_DECISIONS_BRIDGE;
const bridge = bridgeEntry ? (await import(pathToFileURL(bridgeEntry).href)).registerBridge : registerBridge;
const socket = process.argv.includes("--socket");
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/md-"));
const originalEnv = Object.fromEntries(["HOME", "USERPROFILE", "PI_SUBAGENTS_TEMP_ROOT"].map(k => [k, process.env[k]]));
process.env.HOME = process.env.USERPROFILE = join(root, "home");
process.env.PI_SUBAGENTS_TEMP_ROOT = join(root, "native-temp");
await mkdir(process.env.HOME, { recursive: true, mode: 0o700 });
const records = [], eventTypes = [], evidence = [], hosts = [];
let server, currentResult, toolExecutions = 0, fixtureMission;
let nativeApi;
function factory(pi) {
  const executor = nativeApi?.createSubagentExecutor({
    pi, config: { missions: { directory: join(root, "missions"), globalIndex: false }, maxSubagentDepth: 1 },
    asyncByDefault: false, tempArtifactsDir: join(root, "artifacts"),
    getSubagentSessionRoot: () => join(root, "children"), expandTilde: value => value,
    discoverAgents: () => { throw Error("management fixture must not launch a child"); },
    state: { baseCwd: root, currentSessionId: null, asyncJobs: new Map(), foregroundControls: new Map(), lastForegroundControlId: null },
  });
  pi.registerTool({
    name: "subagent", label: "Synthetic mission management", description: "Isolated management-only fixture",
    parameters: nativeApi?.SubagentParams ?? { type: "object", properties: {}, additionalProperties: true },
    async execute(callId, input, signal, onUpdate, ctx) {
      assert.ok(["mission.create", "mission.update", "mission.resolve-decision", "mission.show"].includes(input.action));
      toolExecutions++;
      if (executor) currentResult = await executor.executePublic(callId, nativeApi.flattenSubagentToolOptions(input), signal, onUpdate, ctx);
      else {
        const p = input.options ?? {}, now = new Date().toISOString();
        if (input.action === "mission.create") fixtureMission = { schemaVersion: 1, id: "synthetic-mission", ownerSessionId: ctx.sessionManager.getSessionId(), updatedAt: now, decisions: [], title: "PRIVATE_MISSION_TITLE" };
        if (input.action === "mission.update") fixtureMission = { ...fixtureMission, updatedAt: now, decisions: p.missionUpdate.decisions.map((d, i) => ({ ...d, id: "decision-" + i, status: "open", createdAt: now })) };
        if (input.action === "mission.resolve-decision") fixtureMission = { ...fixtureMission, updatedAt: now, decisions: fixtureMission.decisions.map(d => d.id === input.id ? { ...d, status: "resolved", resolvedAt: now, resolution: input.summary } : d) };
        currentResult = { content: [{ type: "text", text: "PRIVATE_TOOL_CONTENT" }], details: { mode: "management", missionId: fixtureMission.id, mission: structuredClone(fixtureMission) } };
      }
      assert.notEqual(currentResult.isError, true, "native management failed");
      return currentResult;
    },
  });
  for (const type of ["tool_result", "tool_execution_end"]) pi.on(type, event => {
    if (event.toolName === "subagent") eventTypes.push({ type, call: event.toolCallId });
  });
}
const snapshotFor = host => records.filter(r => r.identity.nativeSessionId === host.session.sessionId && r.snapshot).at(-1)?.snapshot;
async function run(host, input, expected) {
  const loadout = { model: host.session.model, thinking: host.session.thinkingLevel, tools: host.session.getActiveToolNames() };
  const before = host.faux.state.callCount, executedBefore = toolExecutions;
  host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("subagent", input), { stopReason: "toolUse" }), ai.fauxAssistantMessage("PRIVATE_DONE")]);
  await host.session.prompt("PRIVATE_SYNTHETIC_PROMPT");
  await host.session.waitForIdle();
  assert.equal(host.faux.state.callCount - before, 2);
  assert.equal(toolExecutions - executedBefore, 1, "observation must not invoke management");
  await until(() => snapshotFor(host)?.missionDecisions?.missions.some(m => m.counts?.open === expected.open && m.counts?.resolved === expected.resolved));
  const snapshot = snapshotFor(host), view = snapshot.missionDecisions.missions[0], original = currentResult.details.mission;
  assert.equal(view.workRef.key, original.id);
  assert.equal(view.sourceUpdatedAt, Date.parse(original.updatedAt));
  assert.deepEqual(view.counts, { ...expected, total: original.decisions.length });
  for (const row of view.decisions) {
    const source = original.decisions.find(d => d.id === row.id);
    assert.equal(row.status, source.status);
    assert.equal(row.createdAt, Date.parse(source.createdAt));
  }
  assert.deepEqual(snapshot.inputs, [], "an open mission decision is not a human-input request");
  assert.deepEqual({ model: host.session.model, thinking: host.session.thinkingLevel, tools: host.session.getActiveToolNames() }, loadout);
  assert.deepEqual(host.errors, []);
  evidence.push({ action: input.action, identity: snapshot.identity, projection: snapshot.missionDecisions });
  return structuredClone(original);
}
try {
  if (native) {
    bindFixturePeerImports();
    const load = file => import(pathToFileURL(join(native, file)).href);
    nativeApi = Object.assign({}, await load("src/runs/foreground/subagent-executor.js"), await load("src/extension/subagent-options.js"), await load("src/extension/schemas.js"));
  }
  if (socket) {
    process.env.PI_DESK_SOCKET = join(root, "desk.sock");
    process.env.PI_DESK_PEER_CHECK = resolve(".build/debug/PiDeskPeerCheck");
    let ready = false, carry = "";
    server = spawn(resolve(".build/debug/PiDeskTransportTests"), ["--serve", process.env.PI_DESK_SOCKET], { stdio: ["pipe", "pipe", "inherit"] });
    server.stdout.on("data", bytes => {
      carry += String(bytes);
      while (carry.includes("\n")) {
        const i = carry.indexOf("\n"), event = JSON.parse(carry.slice(0, i)); carry = carry.slice(i + 1);
        if (event.event === "socket-ready") ready = true;
        if (event.event === "record") { records.push(event.record); if (records.length > 512) records.shift(); }
      }
    });
    await until(() => ready);
  }
  const newHost = async () => {
    const host = await createHost(root, "decisions", { bridge, extensions: [factory], ...(socket ? {} : { transport: () => ({ start() {}, close() {}, reply() {}, publish(record) { records.push(structuredClone(record)); if (records.length > 512) records.shift(); }, dropped: 0 }) }) });
    hosts.push(host); await until(() => snapshotFor(host));
    assert.equal(snapshotFor(host).missionDecisions.coverage, "not-observed", "fresh observer must not scan or infer old records");
    return host;
  };
  const first = await newHost();
  const created = await run(first, { action: "mission.create", options: { mission: { title: "PRIVATE_MISSION_TITLE", objective: "PRIVATE_OBJECTIVE" } } }, { open: 0, resolved: 0 });
  const missionId = created.id;
  const updated = await run(first, { action: "mission.update", options: { missionId, missionUpdate: { decisions: ["A", "B"].map(id => ({ title: "PRIVATE_TITLE_" + id, prompt: "PRIVATE_PROMPT", options: ["PRIVATE_OPTION"], recommendation: "PRIVATE_RECOMMENDATION" })) } } }, { open: 2, resolved: 0 });
  const [a, b] = updated.decisions;
  const resolved = await run(first, { action: "mission.resolve-decision", id: a.id, summary: "PRIVATE_RESOLUTION", options: { missionId } }, { open: 1, resolved: 1 });
  assert.equal(resolved.decisions.find(d => d.id === b.id).status, "open");
  assert.equal(resolved.decisions.find(d => d.id === a.id).resolution, "PRIVATE_RESOLUTION");
  await first.close(); hosts.splice(hosts.indexOf(first), 1);
  const fresh = await newHost();
  assert.notEqual(fresh.session.sessionId, first.session.sessionId);
  const reread = await run(fresh, { action: "mission.show", options: { missionId } }, { open: 1, resolved: 1 });
  assert.equal(reread.ownerSessionId, created.ownerSessionId, "fresh reporter is not the mission creator");
  assert.deepEqual(reread.decisions, resolved.decisions, "ordinary show rereads the same native original");
  assert.equal(reread.updatedAt, resolved.updatedAt);
  const before = snapshotFor(fresh).missionDecisions.scope;
  const firstUser = fresh.session.sessionManager.getEntries().find(e => e.type === "message" && e.message.role === "user");
  await fresh.session.navigateTree(firstUser.id, { summarize: false });
  await until(() => snapshotFor(fresh)?.missionDecisions?.scope !== before);
  assert.equal(snapshotFor(fresh).missionDecisions.coverage, "not-observed");
  assert.equal(fresh.faux.state.callCount, 2, "branch reset adds no model call");
  assert.equal(toolExecutions, 4);
  assert.equal(eventTypes.filter(e => e.type === "tool_result").length, 4);
  assert.equal(eventTypes.filter(e => e.type === "tool_execution_end").length, 4);
  assert.ok(!JSON.stringify(records).includes("PRIVATE_"));
  assert.ok(!JSON.stringify(records.map(r => r.snapshot?.missionDecisions)).includes(root));
  const report = { ok: true, sdk: JSON.parse(await readFile(join(sdkRoot, "package.json"))).version, nativeSource: native ? JSON.parse(await readFile(join(native, "package.json"))).version : "frozen-contract-fixture", realSwiftUDS: socket, bridgeSource: bridgeEntry ? "explicit-entry" : "worktree", nativeManagementCalls: toolExecutions, onlyAResolvedBOpen: true, freshSameOriginal: true, originalCreatorUnchanged: true, branchReset: true, noPrivateFieldsInWire: true, noHumanInputFromOpenDecisions: true, syntheticModelRounds: 8, realProviderCalls: 0, observationAddedModelCalls: 0 };
  if (process.env.PI_DESK_DECISIONS_EVIDENCE) await writeFile(process.env.PI_DESK_DECISIONS_EVIDENCE, JSON.stringify({ report, evidence }, null, 2), { mode: 0o600 });
  console.log(JSON.stringify(report));
} finally {
  for (const host of hosts) await host.close();
  if (server && server.exitCode === null) { const done = new Promise(r => server.once("exit", r)), timer = setTimeout(() => server.kill(), 1000).unref(); server.stdin.end(); await done; clearTimeout(timer); }
  for (const [key, value] of Object.entries(originalEnv)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  await rm(root, { recursive: true, force: true });
}
