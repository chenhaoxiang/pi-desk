import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, ai, until } from "./native-host.mjs";

// Native Pi policy, deterministic offline faux responses; never a business session.
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/recovery-native-"));
const eventTypes = new Set(["agent_start", "agent_end", "agent_settled", "auto_retry_start", "auto_retry_end", "compaction_start", "compaction_end", "tool_execution_start", "tool_execution_end"]);
async function run(enabled, scenario) {
  const records = [], trace = [], checkpoints = [];
  let confirmations = 0, toolCalls = 0, releaseTool, toolStarted = false;
  const host = await createHost(root, scenario, {
    bridge: enabled ? registerBridge : undefined,
    provider: "synthetic-recovery", modelId: "faux",
    transport: () => ({ start() {}, close() {}, reply() {}, publish(r) { records.push(structuredClone(r)); }, dropped: 0 }),
    tools: [{ name: "hold", label: "Synthetic hold", description: "Owned recovery fixture", parameters: { type: "object", properties: {}, additionalProperties: false }, execute: async () => { toolCalls++; toolStarted = true; await new Promise(r => { releaseTool = r; }); return { content: [{ type: "text", text: "SYNTHETIC_TOOL_OK" }], details: {} }; } }],
    bindings: { ui: { confirm: async () => { confirmations++; return false; } } },
  });
  try {
    host.session.setActiveToolsByName(["hold"]);
    host.session.subscribe(e => {
      if (eventTypes.has(e.type)) trace.push({ type: e.type, ...(e.type === "agent_end" || e.type === "compaction_end" ? { willRetry: e.willRetry } : {}), ...(e.type === "compaction_start" || e.type === "compaction_end" ? { reason: e.reason } : {}) });
      if (e.type === "auto_retry_start" || e.type === "compaction_start") checkpoints.push({ event: e.type, calls: host.faux.state.callCount, settled: trace.filter(x => x.type === "agent_settled").length });
    });
    const loadout = () => ({ model: host.session.model.provider + "/" + host.session.model.id, effort: host.session.thinkingLevel, tools: host.session.getActiveToolNames(), prompt: host.session.systemPrompt });
    const before = loadout();
    if (scenario === "retry") {
      host.services.settingsManager.applyOverrides({ retry: { enabled: true, maxRetries: 2, baseDelayMs: 30, maxAgentDelayMs: 60 } });
      host.faux.setResponses([ai.fauxAssistantMessage("", { stopReason: "error", errorMessage: "429 rate limit exceeded" }), ai.fauxAssistantMessage("SYNTHETIC_RECOVERED")]);
      const work = host.session.prompt("synthetic native retry");
      await until(() => host.session.isRetrying);
      if (enabled) {
        await until(() => records.some(r => r.snapshot?.execution === "running"));
        assert.ok(!records.some(r => r.snapshot?.execution === "settled"), "retry does not advertise premature completion");
      }
      await work;
      assert.equal(host.session.getLastAssistantText(), "SYNTHETIC_RECOVERED");
      assert.equal(trace.filter(e => e.type === "auto_retry_start").length, 1);
      assert.equal(trace.filter(e => e.type === "auto_retry_end").length, 1);
      assert.equal(host.faux.state.callCount, 2);
    } else {
      // Public settings force an ordinary native threshold compaction after a
      // completed seed turn. The built-in summarizer consumes the second faux
      // response; it is not an injected lifecycle event or hook replacement.
      host.services.settingsManager.applyOverrides({ compaction: { enabled: true, reserveTokens: host.session.model.contextWindow - 1000, keepRecentTokens: 0 } });
      host.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_SEED_" + "x".repeat(12000)), ai.fauxAssistantMessage("## Goal\nSynthetic recovery fixture\n## Progress\nSeed complete"), ai.fauxAssistantMessage(ai.fauxToolCall("hold", {}), { stopReason: "toolUse" }), ai.fauxAssistantMessage("SYNTHETIC_TOOL_CONTINUED"), ai.fauxAssistantMessage("SYNTHETIC_QUEUED_DONE")]);
      await host.session.prompt("synthetic seed context");
      assert.ok(trace.some(e => e.type === "compaction_start" && e.reason === "threshold"), "native threshold compaction actually ran");
      assert.ok(trace.some(e => e.type === "compaction_end" && e.reason === "threshold"));
      host.session.setAutoCompactionEnabled(false);
      const work = host.session.prompt("synthetic queued tool continuation");
      await until(() => toolStarted);
      host.api.sendUserMessage("synthetic followup", { deliverAs: "followUp" });
      await until(() => host.session.getFollowUpMessages().length === 1);
      if (enabled) assert.notEqual(records.at(-1)?.snapshot?.execution, "settled", "pending tool/queue is not all finished");
      releaseTool(); await work;
      assert.equal(host.session.getLastAssistantText(), "SYNTHETIC_QUEUED_DONE");
      assert.equal(host.faux.state.callCount, 5);
      assert.equal(toolCalls, 1);
    }
    assert.deepEqual(loadout(), before);
    assert.deepEqual(host.errors, []);
    assert.equal(confirmations, 0);
    if (enabled) await until(() => records.some(r => r.snapshot?.execution === "settled"));
    return { trace, checkpoints, calls: host.faux.state.callCount, toolCalls, confirmations, loadout: before, result: host.session.getLastAssistantText() };
  } finally { releaseTool?.(); await host.close(); }
}
const summaries = [];
for (const scenario of ["retry", "compaction-and-queue"]) {
  const baseline = await run(false, scenario), bridge = await run(true, scenario);
  assert.deepEqual(bridge, baseline, "identical native policy/trace/result with bridge on and off");
  summaries.push({ scenario, calls: bridge.calls, toolCalls: bridge.toolCalls, checkpoints: bridge.checkpoints, nativeTrace: bridge.trace, sameTraceAndLoadout: true, addedModelCalls: 0, addedConfirmations: 0 });
}
const result = { ok: true, actualNativePolicy: true, syntheticProviderOnly: true, realProviderCalls: 0, receiverRequired: false, scenarios: summaries };
await writeFile(join(root, "result.json"), JSON.stringify(result, null, 2), { mode: 0o600 });
console.log(JSON.stringify(result));
