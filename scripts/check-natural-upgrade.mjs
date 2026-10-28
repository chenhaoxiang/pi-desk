import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, copyFile, readFile, writeFile, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sdk, ai, until } from "./native-host.mjs";
import { verifyLocal, sha256 } from "./local-install.ts";

const script = fileURLToPath(import.meta.url);
const installed = await verifyLocal(homedir());
const legacySource = "8bd2e809d659830a12c69d083c020efd40876c61";
const tokenKeys = ["input", "output", "cacheRead", "cacheWrite"];

async function child(root, source) {
  const cwd = join(root, "project"), agentDir = join(root, "agent");
  const settings = sdk.SettingsManager.inMemory({ packages: [], retry: { enabled: false }, compaction: { enabled: false } });
  const faux = ai.fauxProvider({ provider: "codex-local-8319", models: [{ id: "gpt-6.1-sol" }], tokensPerSecond: 100000 });
  const runtime = await sdk.ModelRuntime.create({ credentials: new ai.InMemoryCredentialStore(), modelsStore: new ai.InMemoryModelsStore(), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
  runtime.registerNativeProvider(faux.provider);
  await runtime.setRuntimeApiKey("codex-local-8319", "synthetic-fixture-only");
  const loader = new sdk.DefaultResourceLoader({ cwd, agentDir, settingsManager: settings, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true });
  await loader.reload();
  const loaded = loader.getExtensions();
  assert.deepEqual(loaded.errors, []);
  assert.ok(loaded.extensions.some(e => e.resolvedPath === join(agentDir, "extensions/pi-desk-bridge.ts")), "normal extension autodiscovery missing");
  let release, work, toolStarted = false;
  const errors = [];
  const { session } = await sdk.createAgentSession({ cwd, agentDir, modelRuntime: runtime, model: faux.getModel(), thinkingLevel: "high", noTools: "builtin", settingsManager: settings, sessionManager: sdk.SessionManager.inMemory(cwd), resourceLoader: loader,
    customTools: [{ name: "upgrade_fixture_hold", label: "Synthetic hold", description: "Owned offline natural-upgrade check", parameters: { type: "object", properties: {}, additionalProperties: false }, execute: async () => { toolStarted = true; await new Promise(r => { release = r; }); return { content: [{ type: "text", text: "SYNTHETIC_TOOL_DONE" }], details: {} }; } }],
  });
  await session.bindExtensions({ mode: "rpc", onError: e => errors.push(e.message) });
  session.setActiveToolsByName(["upgrade_fixture_hold"]);
  const state = () => ({ pid: process.pid, source, sessionId: session.sessionId, nativeIdle: session.isIdle, modelCalls: faux.state.callCount, toolStarted, errors,
    expected: session.messages.filter(m => m.role === "assistant").reduce((out, m) => { for (const k of tokenKeys) out[k] += m.usage?.[k] ?? 0; return out; }, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }),
  });
  process.on("message", async ({ id, action }) => {
    try {
      if (action === "busy") {
        faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("upgrade_fixture_hold", {}), { stopReason: "toolUse" }), ai.fauxAssistantMessage("SYNTHETIC_GPT_DONE")]);
        work = session.prompt("Owned offline natural upgrade fixture");
        await until(() => toolStarted && !session.isIdle);
      }
      if (action === "idle") { release?.(); await work; await until(() => session.isIdle); }
      if (action === "stop") {
        release?.(); if (work) await work;
        await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" }); session.dispose();
        process.send({ id, state: state() }, () => process.exit(0)); return;
      }
      process.send({ id, state: state() });
    } catch (error) { process.send({ id, error: error.message }); }
  });
  process.send({ ready: true, state: state() });
}

if (process.argv[2] === "--child") {
  await child(process.argv[3], process.argv[4]);
} else {
  const nativeBin = process.env.PI_DESK_NATIVE_BIN;
  const ledgerProbe = process.env.PI_DESK_LEDGER_PROBE;
  assert.ok(nativeBin && ledgerProbe, "explicit owned native test bin and LedgerProbe are required");
  await mkdir("tmp", { recursive: true });
  const root = await mkdtemp(resolve("tmp/nup-"));
  const profile = join(root, "agent"), entry = join(profile, "extensions/pi-desk-bridge.ts"), usageRoot = join(root, "usage-v1");
  await mkdir(dirname(entry), { recursive: true, mode: 0o700 }); await mkdir(join(root, "project"), { mode: 0o700 });
  const legacy = join(homedir(), "Library/Application Support/PiDesk/bridge", legacySource, "src/index.ts");
  await readFile(legacy); // Only the already installed, fixed bridge code; no session/history input.
  await writeFile(entry, `import {registerBridge} from ${JSON.stringify(legacy)}; export default function(pi){registerBridge(pi,{sourceRevision:${JSON.stringify(legacySource)}});}`, { mode: 0o600 });
  const env = { ...process.env, PI_OFFLINE: "1", PI_CODING_AGENT_DIR: profile, PI_DESK_SOCKET: join(root, "desk.sock"), PI_DESK_USAGE_DIR: usageRoot, PI_DESK_PEER_CHECK: join(installed.appPath, "Contents/Helpers/PiDeskPeerCheck") };
  const events = [], children = [];
  const receiver = spawn(join(nativeBin, "PiDeskTransportTests"), ["--serve", env.PI_DESK_SOCKET], { stdio: ["pipe", "pipe", "pipe"] });
  let carry = "";
  receiver.stdout.on("data", chunk => { carry += chunk; while (carry.includes("\n")) { const i = carry.indexOf("\n"); events.push(JSON.parse(carry.slice(0, i))); carry = carry.slice(i + 1); if (events.length > 512) events.shift(); } });
  receiver.stderr.on("data", () => {});
  const latest = id => events.filter(e => e.record?.identity.nativeSessionId === id && e.record?.snapshot).at(-1)?.record.snapshot;
  async function launch(source) {
    const p = spawn(process.execPath, ["--import", "tsx", script, "--child", root, source], { env, stdio: ["ignore", "ignore", "pipe", "ipc"] });
    children.push(p); p.stderr.on("data", () => {});
    const ready = new Promise((resolve, reject) => { p.once("message", m => m.ready ? resolve(m.state) : reject(Error("child-startup-failed"))); p.once("exit", code => reject(Error("child-exited-" + code))); });
    return { p, state: await ready };
  }
  async function command(p, action) {
    const id = action + "-" + Date.now();
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { p.off("message", receive); reject(Error("fixture-command-timeout")); }, 10000);
      const receive = m => { if (m.id !== id) return; clearTimeout(timer); p.off("message", receive); m.error ? reject(Error(m.error)) : resolve(m.state); };
      p.on("message", receive); p.send({ id, action });
    });
  }
  try {
    await until(() => events.some(e => e.event === "socket-ready"));
    const old = await launch(legacySource);
    await until(() => latest(old.state.sessionId));
    assert.equal(latest(old.state.sessionId).executionObservation, undefined);
    await copyFile(installed.entryPath, entry);
    assert.equal(sha256(await readFile(entry)), installed.entrySha256);
    const unchanged = await command(old.p, "sample");
    assert.equal(unchanged.source, legacySource); assert.equal(unchanged.modelCalls, 0);
    assert.equal(latest(old.state.sessionId).capabilities.owners["pi-desk-bridge"], legacySource, "changing the entry cannot hot-reload an existing Pi");
    await command(old.p, "stop");
    await until(() => old.p.exitCode === 0);
    const fresh = await launch(installed.info.sourceCommit);
    await until(() => latest(fresh.state.sessionId)?.executionObservation?.idle === true);
    assert.equal(latest(fresh.state.sessionId).capabilities.owners["pi-desk-bridge"], installed.info.sourceCommit);
    assert.equal(fresh.state.modelCalls, 0, "normal startup/switching must not call a model");
    const busy = await command(fresh.p, "busy");
    await until(() => latest(fresh.state.sessionId)?.execution === "running" && latest(fresh.state.sessionId)?.executionObservation?.idle === false);
    assert.equal(busy.nativeIdle, false);
    const idle = await command(fresh.p, "idle");
    await until(() => latest(fresh.state.sessionId)?.execution === "settled" && latest(fresh.state.sessionId)?.executionObservation?.idle === true);
    assert.equal(idle.nativeIdle, true); assert.equal(idle.modelCalls, 2); assert.deepEqual(idle.errors, []);
    await until(async () => { let n = 0; for (const shard of await readdir(join(usageRoot, "spool")).catch(() => [])) n += (await readdir(join(usageRoot, "spool", shard))).filter(f => /^[a-f0-9]{64}\.json$/.test(f)).length; return n === 2; });
    const aggregate = await new Promise((resolve, reject) => { const p = spawn(ledgerProbe, [usageRoot], { stdio: ["ignore", "pipe", "pipe"] }); let out = ""; p.stdout.on("data", d => { out += d; }); p.once("exit", code => code === 0 ? resolve(JSON.parse(out)) : reject(Error("ledger-probe-failed"))); });
    assert.equal(aggregate.records, 2);
    for (const key of tokenKeys) assert.equal(aggregate[key], idle.expected[key], "native final and SQLite " + key + " disagree");
    assert.ok(aggregate.models.some(m => m.model === "codex-local-8319/gpt-6.1-sol"));
    const result = { ok: true, source: installed.info.sourceCommit, installedBuild: installed.info.build, legacySource, normalAutodiscovery: true, existingRuntimeUnchanged: true, ownedOldProcessClosedNormally: true, startupModelCalls: 0, bridgeStateMatchesNative: true, model: "codex-local-8319/gpt-6.1-sol", sqliteRecords: aggregate.records, tokens: idle.expected, realProviderCalls: 0, historicalReads: 0, transport: "real-swift-uds", root };
    await writeFile(join(root, "result.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
    console.log(JSON.stringify(result));
    await command(fresh.p, "stop");
  } finally {
    for (const p of children) if (p.exitCode === null && p.signalCode === null) p.kill("SIGTERM");
    receiver.stdin.end();
  }
}
