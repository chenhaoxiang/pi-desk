import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { IntercomRelationsObserver, validIntercomRelations } from "../src/intercom-observer.ts";
import { encode, validate } from "../src/protocol.ts";
const at = 1730000000000;
const details = (updatedAt = at, correlation = "late") => ({ messageId: "answer", updatedAt, delivery: "socket_delivered", outcomeKnown: true, execution: "unknown", completion: "unknown", replyState: "not_requested", relations: { version: 1, senderSessionId: "worker:route", recipientSessionId: "asker:route", lateReplyTo: "old-question", replyCorrelation: correlation } });
function begin(o: IntercomRelationsObserver, id: string, value: unknown, action = "status", messageId = "answer") { o.start(id); o.result({ toolCallId: id, toolName: "intercom", isError: false, input: { action, messageId }, details: value }); }
function apply(o: IntercomRelationsObserver, id: string, value = details()) { begin(o, id, value); return o.end(id, { details: value }, false, at + 100); }

test("shared optional relation DTO validates without creating a work binding", () => {
  const p = JSON.parse(readFileSync(new URL("../../../Fixtures/intercom-relations-v1.json", import.meta.url), "utf8"));
  assert.ok(validIntercomRelations(p));
  const wire = JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json", import.meta.url), "utf8"));
  validate(wire); wire.snapshot!.intercomRelations = p; validate(wire); assert.ok(encode(wire).length < 65537);
  assert.equal(p.records[1].replyState, "pending"); assert.equal(p.records[0].relations?.supersededBy, "new-question");
});
test("only finalized current-scope status results can publish, not send arguments or unknown IDs", () => {
  const o = new IntercomRelationsObserver(); begin(o, "first", details()); assert.equal(o.read().coverage, "not-observed");
  assert.ok(o.end("first", { details: details() }, false, at)); assert.equal(o.read().records[0].relations?.lateReplyTo, "old-question");
  for (const [action, id] of [["send", "answer"], ["ask", "answer"], ["status", "wrong"]]) {
    begin(o, action + id, details(at + 1), action, id); assert.equal(o.end(action + id, { details: details(at + 1) }, false, at), false);
  }
  begin(o, "bad-end", details(at + 10)); o.end("bad-end", { details: details(at + 11) }, false, at);
  assert.equal(o.read().records[0].reason, "finalized-mismatch"); assert.equal(o.read().records[0].relations, undefined);
});
test("original timestamps fence older status; equal-time conflicts remain unknown until newer", () => {
  const o = new IntercomRelationsObserver(); apply(o, "new", details(at + 10)); const before = o.read();
  assert.equal(apply(o, "old", details(at)), false); assert.deepEqual(o.read(), before);
  assert.equal(apply(o, "duplicate", details(at + 10)), false);
  assert.ok(apply(o, "conflict", details(at + 10, "unknown"))); assert.equal(o.read().records[0].reason, "same-time-conflict");
  assert.equal(apply(o, "retry", details(at + 10)), false);
  assert.ok(apply(o, "later", details(at + 20))); assert.equal(o.read().records[0].relations?.replyCorrelation, "late");
});
test("missing old-broker fields and receipt uncertainty never become no relation or matched", () => {
  const o = new IntercomRelationsObserver(), missing = { ...details(), relations: undefined };
  apply(o, "old-broker", missing as never); assert.equal(o.read().records[0].reason, "relations-unavailable");
  const unknown = { ...details(at + 1, "unknown"), delivery: "unknown", outcomeKnown: false };
  apply(o, "receipt-unknown", unknown as never); assert.equal(o.read().records[0].relations?.replyCorrelation, "unknown");
  apply(o, "contradiction", { ...details(at + 2), delivery: "unknown", outcomeKnown: false } as never);
  assert.equal(o.read().records[0].coverage, "unavailable");
});
test("errors and reset reject late calls; private text accessors are not read", () => {
  const o = new IntercomRelationsObserver(); let reads = 0;
  const value = details(); for (const key of ["reason", "content", "answer", "maintenance"]) Object.defineProperty(value, key, { get() { reads++; throw Error(); } });
  apply(o, "private", value); assert.equal(reads, 0);
  const before = o.read(); begin(o, "failed", details(at + 2)); assert.equal(o.end("failed", { details: details(at + 2) }, true, at), false); assert.deepEqual(o.read(), before);
  begin(o, "late", details(at + 5)); o.reset(); assert.equal(o.end("late", { details: details(at + 5) }, false, at), false); assert.equal(o.read().coverage, "not-observed");
});
test("bounded stable records, exact omission counts and independent source IDs", () => {
  const o = new IntercomRelationsObserver();
  for (let i = 0; i < 20; i++) {
    const id = "message-" + i, value = { ...details(at + i), messageId: id, relations: { ...details().relations, recipientSessionId: "r".repeat(128) } };
    begin(o, id, value, "status", id); o.end(id, { details: value }, false, at);
  }
  const p = o.read(); assert.equal(p.evictedRecords, 4); assert.equal(p.records.length + p.omitted, 16); assert.ok(p.omitted > 0); assert.ok(validIntercomRelations(p));
  assert.equal(p.records[0].messageId, "message-4"); assert.equal(p.records[0].relations?.senderSessionId, "worker:route");
  const absent = new IntercomRelationsObserver(); assert.equal(absent.read().records.length, 0);
});
