import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { createHost, ai, sdkRoot, until } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
await mkdir("tmp/gpt-chain", { recursive: true });
const root = await mkdtemp(resolve("tmp/gpt-chain/case-"));
const records = [];
const h = await createHost(root, "fresh-gpt", { bridge: registerBridge, provider: "codex-local-8319", modelId: "gpt-6.1-sol", transport: () => ({ start() {}, close() {}, publish(r) { records.push(r); }, reply() {}, dropped: 0 }) });
try {
  h.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_GPT_CHAIN")]);
  await h.session.prompt("Synthetic GPT-named faux session; never a real provider call");
  const spool = join(root, "usage-v1/spool");
  let entries = [];
  await until(async () => {
    entries = [];
    for (const shard of await readdir(spool).catch(() => [])) {
      for (const name of (await readdir(join(spool, shard))).filter(f => /^[a-f0-9]{64}\.json$/.test(f))) entries.push(JSON.parse(await readFile(join(spool, shard, name), "utf8")));
    }
    return entries.length === 1;
  });
  assert.equal(entries[0].model, "codex-local-8319/gpt-6.1-sol");
  assert.ok(Object.values(entries[0].tokens).every(v => Number.isSafeInteger(v) && v >= 0));
  assert.ok(!JSON.stringify(entries).includes("SYNTHETIC_GPT_CHAIN"));
  assert.ok(records.some(r => r.snapshot?.usageRecorder));
  const result = { ok: true, synthetic: true, sdkRoot, model: entries[0].model, stopReason: "stop", timestamp: entries[0].occurredAt, tokens: entries[0].tokens, root, usageRoot: join(root,"usage-v1"), finalReceipts: entries.map(e => e.id), realProviderCalls: 0, errors: h.errors };
  await writeFile(join(root, "result.json"), JSON.stringify(result,null,2), { mode: 0o600 });
  console.log(JSON.stringify(result));
} finally { await h.close(); }
