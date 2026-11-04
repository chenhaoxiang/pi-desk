import { pathToFileURL } from "node:url";
import { realpath } from "node:fs/promises";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DeskAssistant } from "./assistant.ts";
import { validAssistant, type AssistantPayload } from "./assistant-protocol.ts";
import { safeId, type RecordV1 } from "./protocol.ts";

// A bounded, tool-free SDK call, not a Pi/AgentSession or extension loader.
// No session files, prompts, tools, settings writes or credential values cross stdout.
export function localAssistantContext(registry: ExtensionContext["modelRegistry"]): ExtensionContext {
  return { modelRegistry: registry } as ExtensionContext;
}
export function serveLocalAssistant(registry: ExtensionContext["modelRegistry"]) {
  const identity = { localHostId: "pi-desk", nativeSessionId: "local-sdk", runtimeEpoch: "one-shot" };
  let initial: { id: string; operation: string } | undefined;
  let closed = false, carry = "";
  const finish = (payload: AssistantPayload) => {
    if (closed) return; closed = true;
    service.close(); process.stdin.pause();
    process.stdout.write(JSON.stringify(payload) + "\n", () => process.exit(0));
  };
  const service = new DeskAssistant(() => localAssistantContext(registry), identity, (record: RecordV1) => {
    if (record.requestId === initial?.id && record.assistant?.status !== "pending" && record.assistant) finish(record.assistant);
  });
  const cancel = () => {
    if (initial?.operation === "analyze") service.handle({ version: 1, kind: "assistant-request", identity, requestId: "cancel-" + initial.id, issuedAt: Date.now(), assistant: { operation: "cancel", cancelID: initial.id } });
  };
  process.stdout.on("error", () => process.exit(0));
  process.on("SIGTERM", () => { cancel(); setTimeout(() => process.exit(0), 2000).unref(); });
  const timer = setTimeout(() => finish({ operation: initial?.operation ?? "models", status: "unknown", code: "cancel-or-timeout", possibleUsage: initial?.operation === "analyze" }), 125000);
  timer.unref();
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
          if (packet.payload.operation === "cancel" && packet.payload.cancelID === initial.id) cancel();
          continue;
        }
        if (!["models", "analyze"].includes(packet.payload.operation)) throw Error();
        initial = { id: packet.id, operation: packet.payload.operation };
        service.handle({ version: 1, kind: "assistant-request", identity, requestId: packet.id, issuedAt: Date.now(), assistant: packet.payload });
      } catch { finish({ operation: initial?.operation ?? "models", status: "error", code: "assistant-unavailable" }); }
    }
  });
  process.stdin.on("end", () => {
    if (!initial) finish({ operation: "models", status: "error", code: "assistant-unavailable" });
    else if (!closed) { cancel(); setTimeout(() => process.exit(0), 2000).unref(); }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(await realpath(process.argv[1])).href) {
  try {
    const index = process.argv[2];
    if (!index?.endsWith("/dist/index.js")) throw Error();
    const sdk = await import(pathToFileURL(index).href);
    const runtime = await sdk.ModelRuntime.create({ allowModelNetwork: false, refreshOnCreate: false });
    // Populate the public synchronous facade from a fresh, global availability snapshot.
    await runtime.getAvailable();
    serveLocalAssistant(new sdk.ModelRegistry(runtime));
  } catch {
    process.stdout.write(JSON.stringify({ operation: "models", status: "error", code: "registry-unavailable" }) + "\n");
    process.exitCode = 1;
  }
}
