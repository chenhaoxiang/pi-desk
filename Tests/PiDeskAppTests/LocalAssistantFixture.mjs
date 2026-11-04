import { pathToFileURL } from "node:url";
import { serveLocalAssistant } from "../../packages/desk-bridge/src/local-assistant.ts";
const sdk = await import(pathToFileURL(process.argv[2]).href);
const ai = await import("@earendil-works/pi-ai");
const runtime = await sdk.ModelRuntime.create({ credentials: new ai.InMemoryCredentialStore(), modelsStore: new ai.InMemoryModelsStore(), modelsPath: null, refreshOnCreate: false, allowModelNetwork: false });
const faux = ai.fauxProvider({ provider: "desk-local-fixture", models: [{ id: "alpha" }, { id: "beta" }], tokensPerSecond: 100000 });
runtime.registerNativeProvider(faux.provider);
await runtime.setRuntimeApiKey("desk-local-fixture", "synthetic-only");
await runtime.getAvailable();
const registry = new sdk.ModelRegistry(runtime);
faux.setResponses([ai.fauxAssistantMessage(JSON.stringify({ overview: "Synthetic local summary", summaries: [{ ref: "S1", text: "No business session read" }], groups: [] }))]);
serveLocalAssistant({ getAvailable: () => registry.getAvailable().filter(m => m.provider === "desk-local-fixture"), streamSimple(model, context, options) {
  if (JSON.parse(context.messages[0].content).extra === "SYNTHETIC_HOLD") return { result: () => new Promise(resolve => {
    const finish = () => resolve({ role: "assistant", content: [], usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, stopReason: "aborted" });
    if (options.signal.aborted) finish(); else options.signal.addEventListener("abort", finish, { once: true });
  }) };
  return registry.streamSimple(model, context, options);
} });
