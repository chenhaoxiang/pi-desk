import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { createHost, until, bindFixturePeerImports, ai, sdkRoot } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";

// Contract tests, not W3 engineering-work evidence. The opt-in path exercises an
// actual isolated native extension + broker; no live coordination state is used.
const native = process.env.PI_DESK_INTERCOM, socket = process.argv.includes("--socket");
const explicitBridge = process.env.PI_DESK_RELATIONS_BRIDGE;
const bridge = explicitBridge ? (await import(pathToFileURL(explicitBridge).href)).registerBridge : registerBridge;
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/i-"));
const envKeys = ["HOME", "USERPROFILE", "PI_CODING_AGENT_DIR", "PI_INTERCOM_SESSION_ID", "PI_INTERCOM_STABLE_ID", "PI_SUBAGENT_ORCHESTRATOR_TARGET", "PI_SUBAGENT_ORCHESTRATOR_SESSION_ID", "PI_SUBAGENT_RUN_ID", "PI_SUBAGENT_CHILD_AGENT", "PI_SUBAGENT_CHILD_INDEX", "PI_SUBAGENT_INTERCOM_SESSION_NAME", "PI_SUBAGENT_SUPERVISOR_CHANNEL_DIR", "HERDR_PANE_ID"];
const saved = Object.fromEntries(envKeys.map(k => [k, process.env[k]]));
for (const key of envKeys) delete process.env[key];
process.env.HOME = process.env.USERPROFILE = process.env.PI_CODING_AGENT_DIR = root;
const hosts = [], clients = [], records = [], captures = [], evidence = [];
let server, broker, Client, originalConnect, originalStatus, queries = 0, frozen = new Map();
let factory;
const state = host => records.filter(r => r.identity.nativeSessionId === host.session.sessionId && r.snapshot).at(-1)?.snapshot;
async function query(host, messageId, expectedCorrelation, expectedReplyState) {
  const before = host.faux.state.callCount, count = queries, loadout = { tools: host.session.getActiveToolNames(), model: host.session.model, thinking: host.session.thinkingLevel };
  host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("intercom", { action: "status", messageId }), { stopReason: "toolUse" }), ai.fauxAssistantMessage("PRIVATE_DONE")]);
  await host.session.prompt("PRIVATE_STATUS_FIXTURE"); await host.session.waitForIdle();
  assert.equal(host.faux.state.callCount - before, 2);
  assert.equal(queries - count, 1, "Desk must not add native status queries");
  await until(() => state(host)?.intercomRelations?.records.some(r => r.messageId === messageId && (expectedCorrelation === undefined ? r.coverage === "unavailable" : r.relations?.replyCorrelation === expectedCorrelation && r.replyState === expectedReplyState)));
  const snapshot = state(host), observed = snapshot.intercomRelations.records.find(r => r.messageId === messageId);
  const original = captures.at(-1);
  assert.equal(original.messageId, messageId);
  if (expectedCorrelation !== undefined) {
    assert.deepEqual(observed.relations, original.relations);
    assert.equal(observed.sourceUpdatedAt, original.updatedAt);
  }
  assert.deepEqual(snapshot.inputs, []);
  assert.deepEqual(host.errors, []);
  assert.deepEqual({ tools: host.session.getActiveToolNames(), model: host.session.model, thinking: host.session.thinkingLevel }, loadout);
  evidence.push({ identity: snapshot.identity, observation: observed });
  return observed;
}
try {
  if (native) {
    bindFixturePeerImports();
    const load = file => import(pathToFileURL(join(native, file)).href);
    ({ IntercomClient: Client } = await load("broker/client.ts"));
    const { getConfigPath } = await load("config.ts");
    await mkdir(join(root, "intercom"), { recursive: true, mode: 0o700 });
    await writeFile(getConfigPath(), JSON.stringify({ enabled: true, confirmSend: false, inboundTrigger: "never" }), { mode: 0o600 });
    let ready = false, errors = "";
    broker = spawn(process.execPath, ["--import", import.meta.resolve("tsx"), join(native, "broker/broker.ts")], {
      cwd: root, env: { PATH: process.env.PATH, HOME: root, USERPROFILE: root, PI_CODING_AGENT_DIR: root }, stdio: ["ignore", "pipe", "pipe"],
    });
    broker.stdout.on("data", b => { if (String(b).includes("Intercom broker started")) ready = true; });
    broker.stderr.on("data", b => { errors += String(b).slice(0, 2000); });
    await until(() => { if (broker.exitCode !== null) throw Error("isolated-broker-failed: " + errors); return ready; });
    // Observe the test's actual public clients; do not replace their behavior.
    originalConnect = Client.prototype.connect;
    Client.prototype.connect = async function (...args) { const result = await originalConnect.apply(this, args); clients.push(this); return result; };
    originalStatus = Client.prototype.getMessageStatus;
    Client.prototype.getMessageStatus = async function (...args) { queries++; return originalStatus.apply(this, args); };
    factory = (await load("index.ts")).default;
  } else {
    factory = pi => pi.registerTool({ name: "intercom", label: "Frozen Intercom status", description: "Contract fixture only", parameters: { type: "object", properties: {}, additionalProperties: true }, async execute(_id, input) {
      assert.equal(input.action, "status"); queries++;
      return { content: [{ type: "text", text: "PRIVATE_STATUS_BODY" }], details: frozen.get(input.messageId) };
    } });
  }
  if (socket) {
    process.env.PI_DESK_SOCKET = join(root, "desk.sock"); process.env.PI_DESK_PEER_CHECK = resolve(".build/debug/PiDeskPeerCheck");
    let ready = false, carry = "";
    server = spawn(resolve(".build/debug/PiDeskTransportTests"), ["--serve", process.env.PI_DESK_SOCKET], { stdio: ["pipe", "pipe", "inherit"] });
    server.stdout.on("data", b => { carry += String(b); while (carry.includes("\n")) { const i = carry.indexOf("\n"), e = JSON.parse(carry.slice(0, i)); carry = carry.slice(i + 1); if (e.event === "socket-ready") ready = true; if (e.event === "record") { records.push(e.record); if (records.length > 512) records.shift(); } } });
    await until(() => ready);
  }
  for (const name of ["asker", "worker"]) {
    const host = await createHost(root, name, { bridge, extensions: [factory, pi => pi.on("tool_result", event => { if (event.toolName === "intercom") captures.push(structuredClone(event.details)); })],
      ...(socket ? {} : { transport: () => ({ start() {}, close() {}, reply() {}, publish(r) { records.push(structuredClone(r)); if (records.length > 512) records.shift(); }, dropped: 0 }) }) });
    hosts.push(host); await until(() => state(host)?.intercomRelations?.coverage === "not-observed");
    if (native) await until(() => clients.length >= hosts.length);
  }
  const [a, b] = hosts;
  let oldBody, incoming = [];
  if (native) {
    const [asker, worker] = clients;
    asker.on("message", (_from, message) => incoming.push(message));
    assert.equal((await asker.send(worker.sessionId, { messageId: "old-question", text: "PRIVATE_OLD_QUESTION", expectsReply: true })).delivered, true);
    assert.equal((await asker.send(worker.sessionId, { messageId: "new-question", text: "PRIVATE_NEW_QUESTION", expectsReply: true, supersedes: "old-question" })).delivered, true);
    const late = await worker.send(asker.sessionId, { messageId: "late-answer", text: "PRIVATE_OLD_ANSWER", replyTo: "old-question" });
    assert.equal(late.delivered, true); assert.equal(late.demoted, "late_reply");
    await until(() => incoming.some(x => x.id === "late-answer"));
    oldBody = incoming.find(x => x.id === "late-answer").content.text;
    assert.equal(oldBody, "PRIVATE_OLD_ANSWER");
    assert.deepEqual((await asker.listPendingAsks()).map(x => x.messageId), ["new-question"]);
  } else {
    const common = { updatedAt: 1730000000000, delivery: "socket_delivered", outcomeKnown: true, execution: "unknown", completion: "unknown", replyState: "pending" };
    const routing = { version: 1, senderSessionId: "asker:route", recipientSessionId: "worker:route", replyCorrelation: "none" };
    frozen = new Map([
      ["old-question", { ...common, messageId: "old-question", delivery: "failed", replyState: "expired", relations: { ...routing, supersededBy: "new-question" } }],
      ["new-question", { ...common, messageId: "new-question", relations: { ...routing, supersedes: "old-question" } }],
      ["late-answer", { ...common, messageId: "late-answer", replyState: "not_requested", relations: { ...routing, senderSessionId: "worker:route", recipientSessionId: "asker:route", lateReplyTo: "old-question", replyCorrelation: "late" } }],
    ]);
  }
  assert.ok(hosts.every(h => h.faux.state.callCount === 0));
  const old = await query(a, "old-question", "none", "expired"), current = await query(a, "new-question", "none", "pending"), late = await query(b, "late-answer", "late", "not_requested");
  assert.equal(old.relations.supersededBy, "new-question"); assert.equal(current.relations.supersedes, "old-question"); assert.equal(late.relations.lateReplyTo, "old-question");
  assert.equal(late.relations.senderSessionId, current.relations.recipientSessionId);
  assert.equal(late.relations.supersededBy, undefined, "no cross-reporter edge synthesis");
  if (native) {
    assert.equal((await clients[1].send(clients[0].sessionId, { messageId: "current-answer", text: "PRIVATE_PARTIAL_ANSWER", replyTo: "new-question" })).delivered, true);
  } else frozen.set("current-answer", { ...frozen.get("late-answer"), messageId: "current-answer", relations: { version: 1, senderSessionId: "worker:route", recipientSessionId: "asker:route", replyTo: "new-question", replyCorrelation: "matched" } });
  const matched = await query(b, "current-answer", "matched", "not_requested"); assert.equal(matched.relations.replyTo, "new-question");
  if (!native) frozen.set("missing", { messageId: "missing", delivery: "unknown", outcomeKnown: false, replyState: "unknown", execution: "unknown", completion: "unknown" });
  await query(a, native ? "late-answer" : "missing", undefined, undefined);
  if (native) {
    const [asker, worker] = clients;
    const sendReceipt = asker.sendMessageReceipt, held = [];
    asker.sendMessageReceipt = function (receipt) { if (receipt.messageId === "delayed-answer") held.push(receipt); else sendReceipt.call(this, receipt); };
    let pending;
    try {
      assert.equal((await asker.send(worker.sessionId, { messageId: "reused-question", text: "PRIVATE_BEFORE_ACK", expectsReply: true })).delivered, true);
      pending = worker.send(asker.sessionId, { messageId: "delayed-answer", text: "PRIVATE_DELAYED_ANSWER", replyTo: "reused-question" });
      await until(() => incoming.some(x => x.id === "delayed-answer") && held.length > 0);
      assert.equal((await asker.cancelMessage("reused-question")).delivered, true);
      const other = new Client();
      await other.connect({ name: "different-sender", cwd: root, model: "synthetic", pid: process.pid, startedAt: Date.now(), lastActivity: Date.now() });
      assert.equal((await other.send(worker.sessionId, { messageId: "reused-question", text: "PRIVATE_DIFFERENT_ASK", expectsReply: true })).delivered, true);
      asker.sendMessageReceipt = sendReceipt;
      for (const receipt of held) sendReceipt.call(asker, receipt);
      assert.equal((await pending).delivered, true);
      assert.ok((await other.listPendingAsks()).some(x => x.messageId === "reused-question"), "old ACK must not consume a new sender's edge");
      assert.equal(incoming.find(x => x.id === "delayed-answer").content.text, "PRIVATE_DELAYED_ANSWER");
    } finally { asker.sendMessageReceipt = sendReceipt; }
  } else {
    frozen.set("delayed-answer", { ...frozen.get("late-answer"), messageId: "delayed-answer", relations: { version: 1, senderSessionId: "worker:route", recipientSessionId: "asker:route", replyTo: "reused-question", replyCorrelation: "unknown" } });
  }
  const ackUnknown = await query(b, "delayed-answer", "unknown", "not_requested");
  assert.equal(ackUnknown.delivery, "socket_delivered"); assert.equal(ackUnknown.outcomeKnown, true);
  assert.equal(ackUnknown.relations.replyTo, "reused-question"); assert.equal(ackUnknown.relations.lateReplyTo, undefined);
  assert.equal(queries, 6, "foreign query does not reveal another sender's relations; no observer queries");
  assert.ok(!JSON.stringify(records).includes("PRIVATE_"));
  const scope = state(a).intercomRelations.scope;
  const user = a.session.sessionManager.getEntries().find(e => e.type === "message" && e.message.role === "user");
  await a.session.navigateTree(user.id, { summarize: false });
  await until(() => state(a)?.intercomRelations?.scope !== scope); assert.equal(state(a).intercomRelations.coverage, "not-observed");
  const report = { ok: true, source: native ? "actual-isolated-native-extension-and-broker" : "frozen-contract-fixture", sdk: JSON.parse(await readFile(join(sdkRoot, "package.json"))).version, realSwiftUDS: socket, originalReplacementAndLateRefs: true, newAskPendingAfterLate: true, originalBodyPreserved: native ? oldBody === "PRIVATE_OLD_ANSWER" : "not-tested-by-frozen-contract", foreignOrLegacyUnavailable: true, ackReceiptCorrelationUnknown: true, noCrossReporterJoin: true, noHumanInput: true, branchReset: true, statusQueries: queries, observationAddedQueries: 0, syntheticModelRounds: hosts.reduce((n,h) => n + h.faux.state.callCount, 0), realProviderCalls: 0, notW3Evidence: true };
  if (process.env.PI_DESK_RELATIONS_EVIDENCE) await writeFile(process.env.PI_DESK_RELATIONS_EVIDENCE, JSON.stringify({ report, evidence }, null, 2), { mode: 0o600 });
  console.log(JSON.stringify(report));
} finally {
  for (const host of hosts) await host.close();
  for (const client of clients) await client.disconnect();
  if (Client && originalConnect) Client.prototype.connect = originalConnect;
  if (Client && originalStatus) Client.prototype.getMessageStatus = originalStatus;
  for (const child of [server, broker]) if (child && child.exitCode === null) { const done = new Promise(r => child.once("exit", r)); if (child === server) child.stdin.end(); else child.kill("SIGTERM"); const timer = setTimeout(() => child.kill("SIGTERM"), 1000).unref(); await done; clearTimeout(timer); }
  for (const [key,value] of Object.entries(saved)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  await rm(root, { recursive: true, force: true });
}
