import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { createHost, ai, until, sdkRoot } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
await mkdir("tmp/usage-sdk", { recursive: true });
const root = await mkdtemp(resolve("tmp/usage-sdk/case-"));
const records = [];
const transport = () => ({ start() {}, close() {}, publish(r) { records.push(r); }, reply() {}, dropped: 0 });
async function stored() {
  const spool = join(root, "usage-v1/spool"), out = [];
  for (const shard of await readdir(spool).catch(() => [])) {
    for (const file of (await readdir(join(spool, shard))).filter(f => /^[a-f0-9]{64}\.json$/.test(f))) out.push(JSON.parse(await readFile(join(spool, shard, file), "utf8")));
  }
  return out;
}
const hosts = [];
try {
  const a = await createHost(root, "A", { bridge: registerBridge, transport });
  const b = await createHost(root, "B", { bridge: registerBridge, transport });
  hosts.push(a, b);
  const loadout = hosts.map(h => ({ model: h.session.model.id, tools: h.session.getActiveToolNames(), effort: h.session.thinkingLevel, prompt: h.session.systemPrompt }));
  a.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_USAGE_A"), ai.fauxAssistantMessage("SYNTHETIC_USAGE_CONTINUE")]);
  b.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_USAGE_B")]);
  await Promise.all([a.session.prompt("synthetic A"), b.session.prompt("synthetic B")]);
  await until(async () => (await stored()).length === 2);
  // There is no App or UDS receiver in this test; final recording is independent of observation delivery.
  await a.session.prompt("synthetic continuation while UI closed");
  await until(async () => (await stored()).length === 3);
  const entries = await stored();
  assert.equal(new Set(entries.map(e => e.id)).size, 3);
  assert.ok(entries.every(e => e.occurredAt <= Date.now() && e.source === "pi.assistant.final"));
  assert.ok(!JSON.stringify(entries).includes("SYNTHETIC_USAGE_"));
  assert.deepEqual(hosts.map(h => ({ model: h.session.model.id, tools: h.session.getActiveToolNames(), effort: h.session.thinkingLevel, prompt: h.session.systemPrompt })), loadout);
  assert.ok(hosts.every(h => h.errors.length === 0));
  const report = { ok: true, sdkRoot, count: entries.length, twoSessions: true, noAppRequired: true, continuedWhileUIClosed: true, realProviderCalls: 0, addedConfirmations: 0, loadoutUnchanged: true, counts: hosts.map(h => h.faux.state.callCount), usageRoot: join(root, "usage-v1") };
  await writeFile(join(root, "result.json"), JSON.stringify(report, null, 2), { mode: 0o600 });
  console.log(JSON.stringify(report));
} finally { for (const h of hosts) await h.close(); }
