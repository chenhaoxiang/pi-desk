import { pathToFileURL } from "node:url";
import { dirname, join } from "node:path";
import { writeFile } from "node:fs/promises";
import { assistantLifecycle, serveLocalAssistant } from "../../packages/desk-bridge/src/local-assistant.ts";
const sdkPath = process.argv[2], root = process.argv[3];
const sdk = await import(pathToFileURL(sdkPath).href);
const { AuthStorage } = await import(pathToFileURL(join(dirname(sdkPath), "core/auth-storage.js")).href);
const ai = await import("@earendil-works/pi-ai");
const credentials = AuthStorage.create(join(root, "synthetic-auth.json"));
const provider = "desk-oauth-fixture";
await credentials.modify(provider, async () => ({ type: "oauth", access: "synthetic-old-access", refresh: "synthetic-old-refresh", expires: 1 }));
const runtime = await sdk.ModelRuntime.create({ credentials, modelsPath: null, modelsStore: new ai.InMemoryModelsStore(), allowModelNetwork: false });
const faux = ai.fauxProvider({ provider, models: [{ id: "faux" }] });
runtime.registerNativeProvider({ ...faux.provider, auth: { oauth: {
  name: "Synthetic OAuth",
  login() { throw Error("not used"); },
  async refresh() {
    await writeFile(join(root, "refresh-started"), "yes");
    await new Promise(resolve => setTimeout(resolve, 350));
    return { type: "oauth", access: "synthetic-rotated-access", refresh: "synthetic-rotated-refresh", expires: Date.now() + 3600000 };
  },
  async toAuth(value) { return { apiKey: value.access }; },
} } });
await runtime.getAvailable();
const registry = new sdk.ModelRegistry(runtime);
serveLocalAssistant({ getAvailable: () => [faux.getModel("faux")], streamSimple: registry.streamSimple.bind(registry) }, assistantLifecycle(600));
