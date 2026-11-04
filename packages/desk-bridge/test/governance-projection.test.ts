import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { boundGovernance, emptyGovernance, projectOwnerResult, projectWorkHandoff, validGovernanceProjection } from "../src/governance-projection.ts";
import { encode, validate, type RecordV1 } from "../src/protocol.ts";
const fixture = JSON.parse(readFileSync(new URL("../../../Fixtures/work-results-v1.json", import.meta.url), "utf8"));
const result = fixture.results[0].observation, handoff = fixture.handoffs[0].observation;
const baseRecord = (): RecordV1 => JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json", import.meta.url), "utf8"));
test("Pi Vista consumer projection preserves explicit work binding and source limits", () => {
  assert.ok(validGovernanceProjection(fixture));
  const record = baseRecord(); record.snapshot!.governance = fixture; validate(record); assert.ok(encode(record).length < 65536);
  assert.equal(projectOwnerResult(result)?.binding?.workRef.key, "existing-work");
  assert.equal(projectOwnerResult(fixture.results[1].observation)?.decision, "reconcile_required");
  assert.equal(projectWorkHandoff(handoff)?.nextAction, "reconcile");
});
test("projection never evaluates payload getters, readers, raw metadata or tool text", () => {
  let touched = 0;
  const input = { ...result, get readOwner() { touched++; throw Error(); }, get rawContent() { touched++; throw Error(); } };
  assert.deepEqual(projectOwnerResult(input), result); assert.equal(touched, 0);
  assert.equal(projectOwnerResult(new Proxy(input, {get() { touched++; throw Error(); }})), undefined);
  assert.equal(touched, 0);
});
test("handoff/result payloads cannot smuggle write authority, paths or synthetic acceptance", () => {
  assert.equal(projectOwnerResult({ ...result, authorization: "admitted" }), undefined);
  assert.equal(projectOwnerResult({ ...result, decision: "deliverable", outcome: "unknown" }), undefined);
  assert.equal(projectOwnerResult({ ...result, resultRef: "/private/owner.json" }), undefined);
  assert.equal(projectWorkHandoff({ ...handoff, executable: true }), undefined);
  const empty = emptyGovernance("not-applicable"); assert.ok(validGovernanceProjection(empty));
});
test("bounded projection omits complete owner observations and stays partial", () => {
  const many = { ...fixture, observerSeq:16, results: Array.from({ length: 16 }, (_,i) => ({...fixture.results[0], seq:i+1, observation:{...result,resultRef: "r".repeat(128)}})), handoffs: [], omittedResults: 0, omittedHandoffs: 0 };
  const bounded = boundGovernance(many); assert.ok(validGovernanceProjection(bounded)); assert.equal(bounded.coverage, "partial"); assert.ok(bounded.omittedResults > 0);
});
