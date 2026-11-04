import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, access } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { InMemoryCredentialStore, InMemoryModelsStore } from "@earendil-works/pi-ai";
import { ModelRuntime, ModelRegistry } from "@earendil-works/pi-coding-agent";
import { createLocalRegistry } from "../src/local-assistant.ts";

const root = fileURLToPath(new URL("../../../", import.meta.url));
async function until(condition: () => Promise<boolean>) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) { if (await condition()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  throw Error("synthetic OAuth checkpoint missing");
}
test("local SDK restores cached additions, abilities and personalized catalog without network", async () => {
  const credentials = new InMemoryCredentialStore(), modelsStore = new InMemoryModelsStore();
  const options = { credentials, modelsStore, modelsPath: null, allowModelNetwork: false, refreshOnCreate: false };
  const initial = await ModelRuntime.create(options);
  const openai = initial.getModels("openai")[0]!, router = initial.getModels("openrouter")[0]!;
  const changed = { ...openai, reasoning: true, thinkingLevelMap: { medium: null, high: "high" } };
  await modelsStore.write("openai", { models: [changed, { ...openai, id: "synthetic-cached-addition" }], lastModified: Date.now() + 10 ** 12 });
  await modelsStore.write("openrouter", { models: [{ ...router, id: "synthetic-personalized-only" }] });
  await credentials.modify("openai", async () => ({ type: "api_key", key: "synthetic-only" }));
  await credentials.modify("openrouter", async () => ({ type: "api_key", key: "synthetic-only" }));
  const originalFetch = globalThis.fetch; let network = 0;
  globalThis.fetch = async () => { network++; throw Error("network forbidden"); };
  try {
    const registry = await createLocalRegistry({ ModelRuntime, ModelRegistry }, options);
    assert.ok(registry.getAvailable().some(m => m.provider === "openai" && m.id === "synthetic-cached-addition"));
    assert.equal(registry.find("openai", openai.id)?.thinkingLevelMap?.medium, null);
    assert.deepEqual(registry.getAvailable().filter(m => m.provider === "openrouter").map(m => m.id), ["synthetic-personalized-only"]);
    assert.equal(network, 0);
  } finally { globalThis.fetch = originalFetch; }
});
test("cancel, EOF and normal stop drain real SDK OAuth save and lock release before child exit", async () => {
  await mkdir(join(root, "tmp"), { recursive: true });
  const base = await mkdtemp(join(root, "tmp/oauth-drain-"));
  try {
    for (const mode of ["cancel", "eof", "stop", "stdout"]) {
      const run = join(base, mode); await mkdir(run, { mode: 0o700 });
      const sdkPath = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"));
      const child = spawn(process.execPath, [resolve(root, "Tests/PiDeskAppTests/LocalOAuthFixture.mjs"), sdkPath, run], { stdio: ["pipe", "pipe", "pipe"] });
      let output = "", stderr = "";
      child.stdout.on("data", chunk => { output += String(chunk); });
      child.stderr.on("data", chunk => { stderr += String(chunk); });
      const exit = new Promise<number | null>((resolve, reject) => { child.on("exit", resolve); child.on("error", reject); });
      child.stdin.write(JSON.stringify({ id: "oauth-check", payload: { operation: "analyze", provider: "desk-oauth-fixture", modelId: "faux", thinking: "off", sources: [{ ref: "S1", title: "Synthetic", project: "fixture", status: "unknown", tools: [], messages: [] }] } }) + "\n");
      try {
        await until(async () => access(join(run, "refresh-started")).then(() => true, () => false));
        if (mode === "cancel") child.stdin.write(JSON.stringify({ id: "cancel-oauth-check", payload: { operation: "cancel", cancelID: "oauth-check" } }) + "\n");
        else if (mode === "eof") child.stdin.end();
        else if (mode === "stdout") { child.stdout.destroy(); child.stdin.write(JSON.stringify({ id: "cancel-oauth-check", payload: { operation: "cancel", cancelID: "oauth-check" } }) + "\n"); }
        else child.kill("SIGTERM");
        assert.equal(await exit, 0, stderr);
        const stored = JSON.parse(await readFile(join(run, "synthetic-auth.json"), "utf8"));
        assert.equal(stored["desk-oauth-fixture"].refresh, "synthetic-rotated-refresh");
        assert.equal(await access(join(run, "synthetic-auth.json.lock")).then(() => true, () => false), false, "storage lock released before process exit");
        assert.ok(!output.includes("synthetic-rotated") && !output.includes("synthetic-old"), "credential values never cross stdout");
        if (mode === "cancel") assert.equal(JSON.parse(output.trim()).status, "unknown");
      } finally { if (child.exitCode === null) child.kill("SIGTERM"); }
    }
  } finally { await rm(base, { recursive: true, force: true }); }
});
