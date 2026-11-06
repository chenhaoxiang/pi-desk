import test from "node:test";
import assert from "node:assert/strict";
import { projectIntercomRelations } from "../src/intercom-relations.ts";

function source(relations: Record<string, unknown> = {}) {
  return { messageId: "original-message", relations: {
    version: 1, senderSessionId: "intercom-sender", recipientSessionId: "intercom-recipient",
    replyCorrelation: "none", ...relations,
  } };
}

test("preserves only explicit original replacement edges without creating work or approval", () => {
  const original = source({ supersedes: "older-message", supersededBy: "newer-message" });
  const before = structuredClone(original), projected = projectIntercomRelations(original);
  assert.deepEqual(projected, original);
  assert.deepEqual(original, before);
  assert.deepEqual(Object.keys(projected!).sort(), ["messageId", "relations"]);
  assert.equal(projected!.relations.replyCorrelation, "none");
});

test("matched, late and unknown keep distinct original IDs and never infer business applicability", () => {
  for (const [replyCorrelation, key] of [["matched", "replyTo"], ["late", "lateReplyTo"], ["unknown", "replyTo"], ["unknown", "lateReplyTo"]]) {
    const result = projectIntercomRelations(source({ replyCorrelation, [key]: "old-ask" }));
    assert.equal(result?.relations.replyCorrelation, replyCorrelation);
    assert.equal(result?.relations[key as "replyTo" | "lateReplyTo"], "old-ask");
    assert.equal(Object.hasOwn(result!, "workRef"), false);
    assert.equal(Object.hasOwn(result!.relations, "applicability"), false);
  }
  const unknown = projectIntercomRelations(source({ replyCorrelation: "unknown" }));
  assert.equal(unknown?.relations.replyCorrelation, "unknown");
});

test("legacy, missing or unsupported relation metadata stays unavailable rather than none", () => {
  for (const details of [undefined, {}, { messageId: "old" }, { ...source(), relations: null }, source({ version: 2 }), source({ version: undefined }), source({ replyCorrelation: undefined }), source({ replyCorrelation: "approved" }), { ...source(), error: true }]) {
    assert.equal(projectIntercomRelations(details), undefined);
  }
});

test("contradictory reply correlation and self edges are rejected, not repaired by Desk", () => {
  for (const fields of [
    { replyCorrelation: "matched" }, { replyCorrelation: "late" },
    { replyCorrelation: "none", replyTo: "old-ask" }, { replyCorrelation: "none", lateReplyTo: "old-ask" },
    { replyCorrelation: "late", replyTo: "old-ask", lateReplyTo: "old-ask" },
    { replyCorrelation: "matched", lateReplyTo: "old-ask" },
    { replyCorrelation: "unknown", replyTo: "old-ask", lateReplyTo: "another-ask" },
    { supersedes: "original-message" }, { supersededBy: "original-message" },
  ]) assert.equal(projectIntercomRelations(source(fields)), undefined);
});

test("routing identity is independent of the reporting Pi session and never cross-joined", () => {
  const left = projectIntercomRelations(source({ supersededBy: "replacement" }));
  const right = projectIntercomRelations({ messageId: "late-answer", relations: {
    version: 1, senderSessionId: "intercom-recipient", recipientSessionId: "intercom-sender", lateReplyTo: "original-message", replyCorrelation: "late",
  } });
  assert.equal(left?.relations.senderSessionId, "intercom-sender");
  assert.equal(right?.relations.senderSessionId, "intercom-recipient");
  assert.equal(right?.relations.supersededBy, undefined, "do not copy an edge from another reporter");
  assert.equal(left?.relations.replyCorrelation, "none", "a related late answer cannot rewrite this record");
});

test("IDs remain bounded, exact and content-free; unsafe IDs are unavailable, never truncated", () => {
  for (const id of ["", "bad..id", "_leading", "a".repeat(129), "/private/path", "token\nline", "sk-" + "x".repeat(30), "..", "中文描述"]) {
    assert.equal(projectIntercomRelations({ ...source(), messageId: id }), undefined);
    for (const key of ["senderSessionId", "recipientSessionId", "supersedes", "supersededBy", "replyTo", "lateReplyTo"]) {
      assert.equal(projectIntercomRelations(source({ replyCorrelation: "unknown", [key]: id })), undefined);
    }
  }
  assert.equal(projectIntercomRelations(source({ senderSessionId: "route:sender" }))?.relations.senderSessionId, "route:sender");
  const id = "a".repeat(128);
  assert.equal(projectIntercomRelations({ ...source(), messageId: id })?.messageId, id);
});

test("private fields and accessors/proxies are never read or serialized", () => {
  let reads = 0;
  const original = source({ supersedes: "old-ask" });
  for (const obj of [original, original.relations]) {
    for (const key of ["content", "text", "question", "answer", "reason", "bodyText", "toJSON"]) {
      Object.defineProperty(obj, key, { get() { reads++; throw Error("private field read"); } });
    }
  }
  assert.doesNotThrow(() => JSON.stringify(projectIntercomRelations(original)));
  assert.equal(reads, 0);
  const accessor = source();
  Object.defineProperty(accessor.relations, "supersedes", { get() { reads++; throw Error("accessor read"); } });
  assert.equal(projectIntercomRelations(accessor), undefined);
  assert.equal(reads, 0);
  const proxy = new Proxy({}, { getOwnPropertyDescriptor() { reads++; throw Error("proxy read"); }, get() { reads++; throw Error("proxy read"); } });
  assert.equal(projectIntercomRelations(proxy), undefined);
  assert.equal(projectIntercomRelations({ messageId: "test", relations: proxy }), undefined);
  assert.equal(reads, 0);
});
