import { pathToFileURL } from "node:url";
import { realpath } from "node:fs/promises";
import type { CreateModelRuntimeOptions, ExtensionContext, ModelRuntime, ModelRegistry } from "@earendil-works/pi-coding-agent";
import { DeskAssistant } from "./assistant.ts";
import { validAssistant, type AssistantPayload } from "./assistant-protocol.ts";
import { safeId, type RecordV1 } from "./protocol.ts";

// SDK 1.5 OAuth refresh may continue after an aborted caller, under its storage lock.
// Never force-exit this process: keep a 20s safety window beyond the SDK's 15s
// refresh bound, then let outstanding IO/lock releases drain naturally.
export function assistantLifecycle(graceMs = 20000) {
  const controller = new AbortController();
  let stopping = false, onStop = () => {};
  const stop = () => {
    if (stopping) return;
    stopping = true; controller.abort(); onStop();
    process.stdin.pause(); process.stdin.destroy();
    setTimeout(() => { process.exitCode ??= 0; }, graceMs);
  };
  process.on("SIGTERM", stop);
  process.stdout.on("error", stop);
  return { signal: controller.signal, get stopping() { return stopping; }, stop, bind(handler: () => void) { onStop = handler; if (stopping) handler(); } };
}
export async function createLocalRegistry(sdk: { ModelRuntime: typeof ModelRuntime; ModelRegistry: typeof ModelRegistry }, options: CreateModelRuntimeOptions = {}) {
  // Restore stored remote/personalized catalogs without making catalog network requests.
  const runtime = await sdk.ModelRuntime.create({ ...options, allowModelNetwork: false, refreshOnCreate: true });
  return new sdk.ModelRegistry(runtime);
}
export function localAssistantContext(registry: ExtensionContext["modelRegistry"]): ExtensionContext {
  return { modelRegistry: registry } as ExtensionContext;
}
// Bounded, tool-free SDK call; never an AgentSession, extension loader or session file.
export function serveLocalAssistant(registry: ExtensionContext["modelRegistry"], lifecycle = assistantLifecycle()) {
  const identity = { localHostId: "pi-desk", nativeSessionId: "local-sdk", runtimeEpoch: "one-shot" };
  let initial: { id: string; operation: string } | undefined;
  let closed = false, carry = "";
  const finish = (payload: AssistantPayload) => {
    if (closed || lifecycle.stopping) return; closed = true;
    try { process.stdout.write(JSON.stringify(payload) + "\n"); } catch {}
    lifecycle.stop();
  };
  const service = new DeskAssistant(() => localAssistantContext(registry), identity, (record: RecordV1) => {
    if (record.requestId === initial?.id && record.assistant?.status !== "pending" && record.assistant) finish(record.assistant);
  });
  const timer = setTimeout(() => finish({ operation: initial?.operation ?? "models", status: "unknown", code: "cancel-or-timeout", possibleUsage: initial?.operation === "analyze" }), 125000);
  lifecycle.bind(() => { closed = true; clearTimeout(timer); service.close(); });
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk: string) => {
    if (closed) return;
    carry += chunk;
    if (Buffer.byteLength(carry) > 40000) { finish({ operation: initial?.operation ?? "models", status: "error", code: "context-budget" }); return; }
    while (carry.includes("\n")) {
      const end = carry.indexOf("\n"), line = carry.slice(0, end); carry = carry.slice(end + 1);
      try {
        const packet = JSON.parse(line);
        if (!safeId(packet.id) || !validAssistant(packet.payload) || packet.payload.status !== undefined) throw Error();
        if (initial) {
          if (packet.payload.operation === "cancel" && packet.payload.cancelID === initial.id) {
            service.handle({ version: 1, kind: "assistant-request", identity, requestId: packet.id, issuedAt: Date.now(), assistant: packet.payload });
          }
          continue;
        }
        if (!["models", "analyze"].includes(packet.payload.operation)) throw Error();
        initial = { id: packet.id, operation: packet.payload.operation };
        service.handle({ version: 1, kind: "assistant-request", identity, requestId: packet.id, issuedAt: Date.now(), assistant: packet.payload });
      } catch { finish({ operation: initial?.operation ?? "models", status: "error", code: "assistant-unavailable" }); }
    }
  });
  process.stdin.on("end", lifecycle.stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(await realpath(process.argv[1])).href) {
  const lifecycle = assistantLifecycle(); // Install signal handling BEFORE SDK/auth initialization.
  try {
    const index = process.argv[2];
    if (!index?.endsWith("/dist/index.js")) throw Error();
    const sdk = await import(pathToFileURL(index).href);
    const registry = await createLocalRegistry(sdk, { signal: lifecycle.signal });
    if (!lifecycle.stopping) serveLocalAssistant(registry, lifecycle);
  } catch {
    if (!lifecycle.stopping) {
      process.stdout.write(JSON.stringify({ operation: "models", status: "error", code: "registry-unavailable" }) + "\n");
      process.exitCode = 1;
    }
    lifecycle.stop();
  }
}
