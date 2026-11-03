import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { DeskAssistant, recentContext, thinkingLevels } from "../src/assistant.ts";
import { sensitiveText, validAnalysis, validAssistant } from "../src/assistant-protocol.ts";
import { validate, type RecordV1 } from "../src/protocol.ts";

const identity = { localHostId: "fixture", nativeSessionId: "assistant-session", runtimeEpoch: "assistant-epoch" };
const tick = (ms = 15) => new Promise<void>(resolve => setTimeout(resolve, ms));
const analysis = { overview: "合成概览", summaries: [{ ref: "S1", text: "依据合成输入，不代表验收完成" }], groups: [{ name: "合成分组", refs: ["S1"], reason: "用户可选择采纳" }] };
const source = { ref: "S1", title: "Synthetic task", project: "fixture", status: "running", tools: ["read"], messages: [{ id: "entry", role: "user", text: "USER_ALLOWED" }] };
function fixture(options: { hold?: boolean; output?: unknown; timeout?: number; throwProvider?: boolean; usageMode?: "missing" | "zero" } = {}) {
  let calls = 0, businessAborts = 0, ownAborts = 0;
  const captured: { context: unknown; options: unknown }[] = [], replies: RecordV1[] = [];
  const observers = new Set<() => void>();
  const model = { provider: "codex-local-8319", id: "gpt-6.1-sol", name: "Synthetic model", reasoning: true, apiKey: "PRIVATE_NOT_EXPORTED" };
  const businessModel = { provider: "business", id: "unchanged" };
  const entries = new Map<string, unknown>([
    ["leaf", { id: "leaf", parentId: "tool", type: "message", message: { role: "assistant", content: [{ type: "thinking", thinking: "PRIVATE_THINKING" }, { type: "toolCall", name: "bash", arguments: { raw: "PRIVATE_ARGS" } }, { type: "text", text: "ASSISTANT_ALLOWED" }] } }],
    ["tool", { id: "tool", parentId: "user", type: "message", message: { role: "toolResult", content: [{ type: "text", text: "PRIVATE_TOOL_RESULT" }] } }],
    ["user", { id: "user", parentId: "secret", type: "message", message: { role: "user", content: [{ type: "text", text: "USER_ALLOWED" }, { type: "image", data: "PRIVATE_IMAGE" }] } }],
    ["secret", { id: "secret", parentId: null, type: "message", message: { role: "user", content: "Authorization: Bearer " + ["SYNTHETIC", "NOT", "A", "REAL", "CREDENTIAL"].join("_") } }],
    ["other-branch", { id: "other-branch", parentId: null, type: "message", message: { role: "user", content: "PRIVATE_OTHER_BRANCH" } }],
  ]);
  const ctx = {
    model: businessModel, abort() { businessAborts++; },
    sessionManager: { getLeafId: () => "leaf", getEntry: (id: string) => entries.get(id), getBranch() { throw Error("whole branch traversal must not run"); } },
    modelRegistry: {
      getAvailable: () => [model],
      streamSimple(_model: unknown, context: unknown, streamOptions: { signal?: AbortSignal; reasoning?: string }) {
        calls++; captured.push({ context, options: streamOptions });
        const response = () => ({ role: "assistant", provider: model.provider, model: model.id, content: [{ type: "text", text: JSON.stringify(options.output ?? analysis) }], stopReason: "stop", usage: options.usageMode === "missing" ? undefined : options.usageMode === "zero" ? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } : { input: 10, output: 20, cacheRead: 3, cacheWrite: 0 } });
        return { result: () => {
          if (options.throwProvider) return Promise.reject(Error("PRIVATE_PROVIDER_HEADER"));
          if (!options.hold) return Promise.resolve(response());
          return new Promise(resolve => streamOptions.signal?.addEventListener("abort", () => { ownAborts++; resolve({ ...response(), stopReason: "aborted" }); }, { once: true }));
        } };
      },
    },
  } as unknown as ExtensionContext;
  const service = new DeskAssistant(() => ctx, identity, record => { validate(record); replies.push(structuredClone(record)); for (const observer of observers) observer(); }, () => 1000, options.timeout ?? 120000);
  const request = (id: string, operation: string, extra: object = {}): RecordV1 => ({ version: 1, kind: "assistant-request", identity, requestId: id, issuedAt: 1000, assistant: { operation, ...extra } });
  const generate = (id = "analysis-1", extra: object = {}) => request(id, "analyze", { provider: model.provider, modelId: model.id, thinking: "medium", sources: [source], ...extra });
  function settled(id: string, status?: string) {
    const ready = () => replies.some(r => r.requestId === id && (status ? r.assistant?.status === status : r.assistant?.status !== "pending"));
    if (ready()) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      const observer = () => { if (ready()) { clearTimeout(timer); observers.delete(observer); resolve(); } };
      const timer = setTimeout(() => { observers.delete(observer); reject(Error("bounded assistant completion missing")); }, 10000);
      observers.add(observer);
    });
  }
  return { service, ctx, replies, captured, request, generate, settled, counts: () => ({ calls, businessAborts, ownAborts }), businessModel };
}

test("shared Swift/Node assistant golden keeps the default route and medium effort", () => {
  const golden = JSON.parse(readFileSync(new URL("../../../Fixtures/assistant-v1.json", import.meta.url), "utf8"));
  validate(golden.request); validate(golden.response);
  assert.equal(golden.request.assistant.provider, "codex-local-8319");
  assert.equal(golden.request.assistant.modelId, "gpt-6.1-sol");
  assert.equal(golden.request.assistant.thinking, "medium");
});

test("explicit registry and context reads never call a model or export private fields", async () => {
  const f = fixture();
  try {
    f.service.handle(f.request("models-1", "models")); f.service.handle(f.request("context-1", "context")); await Promise.all([f.settled("models-1"), f.settled("context-1")]);
    assert.equal(f.counts().calls, 0);
    assert.equal(f.replies.find(r => r.requestId === "models-1")?.assistant?.models?.[0]?.provider, "codex-local-8319");
    const context = f.replies.find(r => r.requestId === "context-1")?.assistant;
    assert.deepEqual(context?.messages?.map(m => m.text), ["USER_ALLOWED", "ASSISTANT_ALLOWED"]);
    assert.equal(context?.partial, true);
    assert.ok(!JSON.stringify(f.replies).includes("PRIVATE"));
  } finally { f.service.close(); }
});
test("bounded parent traversal avoids file discovery, whole branch scans and cycles", () => {
  let reads = 0;
  const ctx = { sessionManager: { getLeafId: () => "n0", getEntry(id: string) { reads++; return { id, parentId: "n" + (Number(id.slice(1)) + 1), type: "label" }; }, getBranch() { throw Error("forbidden"); } } } as unknown as ExtensionContext;
  assert.equal(recentContext(ctx, identity).partial, true); assert.equal(reads, 128);
});
test("one explicit medium analysis is tool-free, scoped and deduplicated without business mutation", async () => {
  const f = fixture();
  try {
    const original = structuredClone(f.businessModel), r = f.generate();
    f.service.handle(r); await f.settled("analysis-1");
    assert.equal(f.counts().calls, 1); assert.equal(f.counts().businessAborts, 0); assert.deepEqual(f.ctx.model, original);
    assert.equal((f.captured[0].options as { reasoning: string }).reasoning, "medium");
    assert.equal((f.captured[0].context as { tools?: unknown }).tools, undefined);
    const result = f.replies.at(-1)?.assistant;
    assert.equal(result?.status, "ok"); assert.deepEqual(result?.analysis, analysis); assert.equal(result?.usage?.output, 20);
    f.service.handle(r); assert.equal(f.counts().calls, 1, "same request cannot spend again");
    f.service.handle({ ...r, assistant: { ...r.assistant!, extra: "changed" } });
    assert.equal(f.replies.at(-1)?.assistant?.code, "request-conflict"); assert.equal(f.counts().calls, 1);
  } finally { f.service.close(); }
});
test("sensitive input and unsupported model/thinking never silently route or call a provider", async () => {
  const f = fixture();
  try {
    f.service.handle(f.generate("sensitive", { extra: "密码=" + "123456" }));
    f.service.handle(f.generate("forbidden", { provider: "cphone" }));
    f.service.handle(f.generate("unsupported", { thinking: "max" })); await Promise.all([f.settled("sensitive"), f.settled("forbidden"), f.settled("unsupported")]);
    assert.equal(f.counts().calls, 0);
    assert.deepEqual(f.replies.map(r => r.assistant?.code).sort(), ["context-sensitive", "model-unavailable", "thinking-unsupported"].sort());
    assert.equal(sensitiveText("Authorization: Bearer " + "test_credential_for_fixture"), true);
    assert.equal(thinkingLevels({ reasoning: false }).includes("medium"), false);
  } finally { f.service.close(); }
});
test("cancelling and deadlines target only the assistant signal, not ctx.abort", async () => {
  const f = fixture({ hold: true });
  try {
    f.service.handle(f.generate()); await f.settled("analysis-1", "pending");
    f.service.handle(f.request("cancel-1", "cancel", { cancelID: "analysis-1" })); await Promise.all([f.settled("cancel-1"), f.settled("analysis-1")]);
    assert.deepEqual(f.counts(), { calls: 1, businessAborts: 0, ownAborts: 1 });
    assert.equal(f.replies.find(r => r.requestId === "analysis-1" && r.assistant?.status === "unknown")?.assistant?.possibleUsage, true);
  } finally { f.service.close(); }
  const deadline = fixture({ hold: true, timeout: 5 });
  try { deadline.service.handle(deadline.generate()); await deadline.settled("analysis-1"); assert.equal(deadline.counts().businessAborts, 0); assert.equal(deadline.replies.at(-1)?.assistant?.code, "cancel-or-timeout"); }
  finally { deadline.service.close(); }
});
test("invalid refs and provider errors remain errors, never new execution instructions or automatic retries", async () => {
  for (const options of [{ output: { ...analysis, summaries: [{ ref: "UNKNOWN", text: "invented" }] } }, { throwProvider: true }]) {
    const f = fixture(options);
    try { f.service.handle(f.generate()); await f.settled("analysis-1"); assert.equal(f.counts().calls, 1); assert.equal(f.replies.at(-1)?.assistant?.status, "error"); assert.ok(!JSON.stringify(f.replies).includes("PRIVATE_PROVIDER_HEADER")); }
    finally { f.service.close(); }
  }
});
test("successful nonempty output with missing or SDK-default zero usage remains usage-unconfirmed", async () => {
  for (const usageMode of ["missing", "zero"] as const) {
    const f = fixture({ usageMode });
    try {
      f.service.handle(f.generate()); await f.settled("analysis-1");
      const reply = f.replies.at(-1)?.assistant;
      assert.equal(reply?.status, "ok"); assert.deepEqual(reply?.analysis, analysis);
      assert.equal(reply?.possibleUsage, true, "valid analysis is not a usage settlement receipt");
      if (usageMode === "missing") assert.equal(reply?.usage, undefined);
      else assert.deepEqual(reply?.usage, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
      assert.equal(f.counts().calls, 1);
    } finally { f.service.close(); }
  }
});
test("assistant schema rejects oversized arrays, unrecognized refs, unsupported kinds and stale identities", async () => {
  assert.equal(validAssistant({ operation: "analyze", sources: Array(9).fill(source) }), false);
  assert.equal(validAnalysis({ ...analysis, groups: [{ name: "g", refs: ["UNKNOWN"], reason: "" }] }, new Set(["S1"])), false);
  const f = fixture();
  try { f.service.handle({ ...f.generate(), identity: { ...identity, runtimeEpoch: "stale" } }); await tick(); assert.equal(f.counts().calls, 0); assert.equal(f.replies.length, 0); }
  finally { f.service.close(); }
});
