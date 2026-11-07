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
const typed = process.argv.includes("--typed");
const legacyEntry = process.env.PI_DESK_LEGACY_DECISIONS;
const legacyValid = legacyEntry ? (await import(pathToFileURL(legacyEntry).href)).validMissionDecisions : undefined;
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/md-"));
const originalEnv = Object.fromEntries(["HOME", "USERPROFILE", "PI_SUBAGENTS_TEMP_ROOT"].map(k => [k, process.env[k]]));
process.env.HOME = process.env.USERPROFILE = join(root, "home");
process.env.PI_SUBAGENTS_TEMP_ROOT = join(root, "native-temp");
await mkdir(process.env.HOME, { recursive: true, mode: 0o700 });
const records = [], eventTypes = [], evidence = [], hosts = [];
let server, currentResult, toolExecutions = 0, fixtureMission;
let rounds = 0, expectedCalls = 4;
const errorResults = [];
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
        const p = input.options ?? {}, now = new Date(Math.max(Date.now(),Date.parse(fixtureMission?.updatedAt??"1970-01-01")+1)).toISOString();
        if (input.action === "mission.create") fixtureMission = { schemaVersion: 1, id: "synthetic-mission", ownerSessionId: ctx.sessionManager.getSessionId(), updatedAt: now, decisions: [], title: "PRIVATE_MISSION_TITLE" };
        if (input.action === "mission.update" && p.missionUpdate.decisions) {
          const added=p.missionUpdate.decisions.map((d,i)=>({...d,id:"decision-"+(fixtureMission.decisions.length+i),status:"open",createdAt:now}));
          fixtureMission={...fixtureMission,updatedAt:now,decisions:[...fixtureMission.decisions,...added]};
        }
        const closure=input.action === "mission.resolve-decision" ? {id:input.id,reason:typed?"answered":undefined,resolution:input.summary} : p.missionUpdate?.closeDecision;
        if(closure){
          const row=fixtureMission.decisions.find(d=>d.id===closure.id);
          if(!row||row.status!=="open")throw Error("synthetic exact decision already resolved");
          fixtureMission={...fixtureMission,updatedAt:now,decisions:fixtureMission.decisions.map(d=>d.id===closure.id?{...d,status:"resolved",resolvedAt:now,resolution:closure.resolution,...(closure.reason?{closeReason:closure.reason}:{}),...(closure.supersededBy?{supersededBy:closure.supersededBy}:{})}:d)};
        }
        currentResult = { content: [{ type: "text", text: "PRIVATE_TOOL_CONTENT" }], details: { mode: "management", missionId: fixtureMission.id, mission: structuredClone(fixtureMission) } };
      }
      assert.notEqual(currentResult.isError, true, "native management failed");
      return currentResult;
    },
  });
  for (const type of ["tool_result", "tool_execution_end"]) pi.on(type, event => {
    if (event.toolName === "subagent") {
      eventTypes.push({ type, call: event.toolCallId });
      if(type==="tool_result"&&event.isError)errorResults.push(event.toolCallId);
    }
  });
}
const snapshotFor = host => records.filter(r => r.identity.nativeSessionId === host.session.sessionId && r.snapshot).at(-1)?.snapshot;
async function run(host, input, expected) {
  const loadout = { model: host.session.model, thinking: host.session.thinkingLevel, tools: host.session.getActiveToolNames() };
  const before = host.faux.state.callCount, executedBefore = toolExecutions;
  host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("subagent", input), { stopReason: "toolUse" }), ai.fauxAssistantMessage("PRIVATE_DONE")]);
  await host.session.prompt("PRIVATE_SYNTHETIC_PROMPT");
  await host.session.waitForIdle();
  assert.equal(host.faux.state.callCount - before, 2);rounds+=2;
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
    for(const field of ["closeReason","supersedes","supersededBy"])assert.equal(row[field],source[field]);
  }
  if(legacyValid)assert.ok(legacyValid(snapshot.missionDecisions),"actual legacy validator ignores additive typed fields");
  assert.deepEqual(snapshot.inputs, [], "an open mission decision is not a human-input request");
  assert.deepEqual({ model: host.session.model, thinking: host.session.thinkingLevel, tools: host.session.getActiveToolNames() }, loadout);
  assert.deepEqual(host.errors, []);
  evidence.push({ action: input.action, identity: snapshot.identity, projection: snapshot.missionDecisions });
  return structuredClone(original);
}
async function rejectUnchanged(host,input) {
  const before=structuredClone(snapshotFor(host).missionDecisions),executed=toolExecutions,errors=errorResults.length;
  const calls=host.faux.state.callCount;
  host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("subagent",input),{stopReason:"toolUse"}),ai.fauxAssistantMessage("PRIVATE_DONE")]);
  await host.session.prompt("PRIVATE_REJECTED_REQUEST");await host.session.waitForIdle();
  assert.equal(host.faux.state.callCount-calls,2);rounds+=2;
  assert.equal(toolExecutions-executed,1);assert.equal(errorResults.length-errors,1);
  assert.deepEqual(snapshotFor(host).missionDecisions,before,"failed native closure cannot change projection, original time or seq");
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
  let resolved;
  if(typed){
    const intent=await run(first,{action:"mission.update",options:{missionId,missionUpdate:{decisions:[{title:"PRIVATE_NEW_TITLE",supersedes:a.id}]}}},{open:3,resolved:0});
    const replacement=intent.decisions.at(-1);
    assert.equal(replacement.supersedes,a.id);assert.equal(intent.decisions.find(d=>d.id===a.id).status,"open");
    assert.equal(snapshotFor(first).missionDecisions.missions[0].decisions.find(d=>d.id===a.id).supersededBy,undefined);
    await run(first,{action:"mission.update",options:{missionId,missionUpdate:{closeDecision:{id:a.id,reason:"superseded",supersededBy:replacement.id,resolution:"PRIVATE_CLOSE"}}}},{open:2,resolved:1});
    await run(first,{action:"mission.update",options:{missionId,missionUpdate:{closeDecision:{id:b.id,reason:"withdrawn",resolution:"PRIVATE_WITHDRAW"}}}},{open:1,resolved:2});
    const answered=await run(first,{action:"mission.resolve-decision",id:replacement.id,summary:"PRIVATE_RESOLUTION",options:{missionId}},{open:0,resolved:3});
    assert.equal(answered.decisions.find(d=>d.id===a.id).closeReason,"superseded");
    assert.equal(answered.decisions.find(d=>d.id===b.id).closeReason,"withdrawn");
    assert.equal(answered.decisions.find(d=>d.id===replacement.id).closeReason,"answered");
    const gap=await run(first,{action:"mission.update",options:{missionId,missionUpdate:{decisions:[{title:"PRIVATE_GAP_OLD"}]}}},{open:1,resolved:3});
    const gapOld=gap.decisions.at(-1);
    const gapIntent=await run(first,{action:"mission.update",options:{missionId,missionUpdate:{decisions:[{title:"PRIVATE_GAP_NEW",supersedes:gapOld.id}]}}},{open:2,resolved:3});
    const gapNew=gapIntent.decisions.at(-1);
    resolved=await run(first,{action:"mission.resolve-decision",id:gapOld.id,summary:"PRIVATE_GAP_ANSWER",options:{missionId}},{open:1,resolved:4});
    assert.equal(resolved.decisions.find(d=>d.id===gapOld.id).closeReason,"answered");
    await rejectUnchanged(first,{action:"mission.update",options:{missionId,missionUpdate:{closeDecision:{id:gapOld.id,reason:"superseded",supersededBy:gapNew.id,resolution:"PRIVATE_LATE_CLOSE"}}}});
    expectedCalls=11;
  }else{
    resolved=await run(first,{action:"mission.resolve-decision",id:a.id,summary:"PRIVATE_RESOLUTION",options:{missionId}},{open:1,resolved:1});
    assert.equal(resolved.decisions.find(d=>d.id===b.id).status,"open");
    assert.equal(resolved.decisions.find(d=>d.id===a.id).resolution,"PRIVATE_RESOLUTION");
  }
  await first.close(); hosts.splice(hosts.indexOf(first), 1);
  const fresh = await newHost();
  assert.notEqual(fresh.session.sessionId, first.session.sessionId);
  const reread = await run(fresh, { action: "mission.show", options: { missionId } }, { open: 1, resolved: typed ? 4 : 1 });
  assert.equal(reread.ownerSessionId, created.ownerSessionId, "fresh reporter is not the mission creator");
  assert.deepEqual(reread.decisions, resolved.decisions, "ordinary show rereads the same native original");
  assert.equal(reread.updatedAt, resolved.updatedAt);
  const before = snapshotFor(fresh).missionDecisions.scope;
  const firstUser = fresh.session.sessionManager.getEntries().find(e => e.type === "message" && e.message.role === "user");
  await fresh.session.navigateTree(firstUser.id, { summarize: false });
  await until(() => snapshotFor(fresh)?.missionDecisions?.scope !== before);
  assert.equal(snapshotFor(fresh).missionDecisions.coverage, "not-observed");
  assert.equal(fresh.faux.state.callCount, 2, "branch reset adds no model call");
  assert.equal(toolExecutions, expectedCalls);
  assert.equal(eventTypes.filter(e => e.type === "tool_result").length, expectedCalls);
  assert.equal(eventTypes.filter(e => e.type === "tool_execution_end").length, expectedCalls);
  assert.ok(!JSON.stringify(records).includes("PRIVATE_"));
  assert.ok(!JSON.stringify(records.map(r => r.snapshot?.missionDecisions)).includes(root));
  const report = { ok: true, sdk: JSON.parse(await readFile(join(sdkRoot, "package.json"))).version, nativeSource: native ? JSON.parse(await readFile(join(native, "package.json"))).version : "frozen-contract-fixture", realSwiftUDS: socket, bridgeSource: bridgeEntry ? "explicit-entry" : "worktree", nativeManagementCalls: toolExecutions, onlyAResolvedBOpen: !typed, typedReplacementWithdrawal:typed, nonAtomicGapAnswered:typed, failedClosureProjectionUnchanged:typed, actualLegacyValidator:!!legacyValid, freshSameOriginal: true, originalCreatorUnchanged: true, branchReset: true, noPrivateFieldsInWire: true, noHumanInputFromOpenDecisions: true, syntheticModelRounds: rounds, realProviderCalls: 0, observationAddedModelCalls: 0 };
  if (process.env.PI_DESK_DECISIONS_EVIDENCE) await writeFile(process.env.PI_DESK_DECISIONS_EVIDENCE, JSON.stringify({ report, evidence }, null, 2), { mode: 0o600 });
  console.log(JSON.stringify(report));
} finally {
  for (const host of hosts) await host.close();
  if (server && server.exitCode === null) { const done = new Promise(r => server.once("exit", r)), timer = setTimeout(() => server.kill(), 1000).unref(); server.stdin.end(); await done; clearTimeout(timer); }
  for (const [key, value] of Object.entries(originalEnv)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  await rm(root, { recursive: true, force: true });
}
