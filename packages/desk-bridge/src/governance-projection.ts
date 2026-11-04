import { types } from "node:util";
import { sensitiveText } from "./assistant-protocol.ts";

// Display copies of Pi Vista metadata, not acceptance policy or current proof.
export type WorkRef = { owner: string; kind: "issue" | "change" | "task" | "document"; key: string };
export type WorkBinding = { workRef: WorkRef; stageId: string; runId: string; sessionId: string; revision: number; headSha?: string };
export type OwnerResult = { binding: WorkBinding | null; resultRef?: string; decision: "deliverable" | "reportable_terminal" | "reconcile_required"; outcome: "accepted" | "failed" | "unknown"; reasonCode: string; authorization: "none"; readOnly: true };
export type WorkHandoff = {
  previous: WorkBinding | null; successor: WorkBinding | null; decision: "handoff_observed" | "reconcile_required";
  reasonCode: string; acceptedFactRefs: string[]; unresolvedEffectRefs: string[]; blockerRefs: string[];
  nextAction: "reconcile" | "continue" | "wait" | "close" | "handoff" | "none";
  sourceHeadRecheckRequired: true; currentVerification: "not_checked"; authorization: "none"; executable: false; readOnly: true;
};
export type ObservedResult = { seq: number; observedAt: number; observation: OwnerResult };
export type ObservedHandoff = { seq: number; observedAt: number; observation: WorkHandoff };
export type GovernanceProjection = {
  version: 1; source: "pi.vista";
  coverage: "not-observed" | "not-applicable" | "observed" | "partial" | "unavailable";
  observerEpoch?: string; observerSeq?: number; observedAt?: number; stale?: boolean;
  results: ObservedResult[]; handoffs: ObservedHandoff[];
  /** Source window evictions, not a work/task count. */
  omittedObservations: number; omittedResults: number; omittedHandoffs: number;
};
export const own = (value: unknown, key: string): unknown => {
  if (value === null || typeof value !== "object" || types.isProxy(value)) return undefined;
  const d = Object.getOwnPropertyDescriptor(value, key); return d && "value" in d ? d.value : undefined;
};
export const safeReference = (v: unknown, max = 128): v is string => typeof v === "string" && v.length > 0 && v.length <= max && /^[A-Za-z0-9._-]+$/.test(v) && v !== "." && v !== ".." && !sensitiveText(v);
export const safeObservationReference = (v: unknown): v is string => typeof v === "string" && v.length > 0 && v.length <= 256 && !sensitiveText(v) && !/[\u0000-\u001f\u007f\u0080-\u009f]/.test(v) && !/(?:^|[\\/])(?:Users|home|private|var|tmp|etc|opt|workspace|src)(?:[\\/]|$)|^[A-Za-z]:[\\/]/u.test(v) && !/(?:&&|\|\||[;`$<>]|\r?\n)/.test(v) && !/:\/\/[^/\s:]+:[^@/\s]+@/u.test(v) && !/(?:^|[^a-z0-9])(?:args?|argv|command|completion|content|cwd|directory|file(?:name|path)?|input|model|output|path|prompt|raw|request|response|secret|shell|stderr|stdin|stdout|token|credential|password)(?:$|[^a-z0-9])/iu.test(v);
export const uint = (v: unknown, max = Number.MAX_SAFE_INTEGER): v is number => Number.isSafeInteger(v) && Number(v) >= 0 && Number(v) <= max;
export function dense(value: unknown, max: number): unknown[] | undefined {
  if (!Array.isArray(value) || types.isProxy(value) || Object.getPrototypeOf(value) !== Array.prototype || !uint(own(value, "length"), max)) return;
  const result: unknown[] = [];
  for (let i = 0; i < value.length; i++) { const d = Object.getOwnPropertyDescriptor(value, String(i)); if (!d || !("value" in d)) return; result.push(d.value); }
  return result;
}
export function projectWorkBinding(value: unknown): WorkBinding | undefined {
  const ref = own(value, "workRef"), owner = own(ref, "owner"), kind = own(ref, "kind"), key = own(ref, "key");
  if (typeof owner !== "string" || owner.length > 256 || !/^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)?$/.test(owner) || !owner.split("/").every(x => safeReference(x, 256)) || !["issue", "change", "task", "document"].some(x => kind === x) || !safeReference(key)) return;
  const stageId = own(value, "stageId"), runId = own(value, "runId"), sessionId = own(value, "sessionId"), revision = own(value, "revision"), headSha = own(value, "headSha");
  if (!safeReference(stageId) || !safeReference(runId) || !safeReference(sessionId) || !uint(revision) || (headSha !== undefined && (typeof headSha !== "string" || !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(headSha)))) return;
  return { workRef: { owner, kind: kind as WorkRef["kind"], key }, stageId, runId, sessionId, revision, ...(typeof headSha === "string" ? { headSha } : {}) };
}
function nullableBinding(value: unknown): WorkBinding | null | undefined { return value === null ? null : projectWorkBinding(value); }
export function projectOwnerResult(value: unknown): OwnerResult | undefined {
  const binding = nullableBinding(own(value, "binding")), resultRef = own(value, "resultRef"), decision = own(value, "decision"), outcome = own(value, "outcome"), reasonCode = own(value, "reasonCode");
  if (binding === undefined || (resultRef !== undefined && !safeReference(resultRef)) || !safeReference(reasonCode) || own(value, "authorization") !== "none" || own(value, "readOnly") !== true) return;
  if (!(decision === "deliverable" && outcome === "accepted" && binding && reasonCode === "owner_acceptance_confirmed") && !(decision === "reportable_terminal" && outcome === "failed" && binding) && !(decision === "reconcile_required" && outcome === "unknown")) return;
  return { binding, ...(typeof resultRef === "string" ? { resultRef } : {}), decision: decision as OwnerResult["decision"], outcome: outcome as OwnerResult["outcome"], reasonCode, authorization: "none", readOnly: true };
}
export function projectWorkHandoff(value: unknown): WorkHandoff | undefined {
  const previous = nullableBinding(own(value, "previous")), successor = nullableBinding(own(value, "successor")), decision = own(value, "decision"), reasonCode = own(value, "reasonCode"), nextAction = own(value, "nextAction");
  const a = dense(own(value, "acceptedFactRefs"), 64), u = dense(own(value, "unresolvedEffectRefs"), 64), b = dense(own(value, "blockerRefs"), 64);
  if (previous === undefined || successor === undefined || !["handoff_observed", "reconcile_required"].some(x => x === decision) || !safeReference(reasonCode) || !["reconcile", "continue", "wait", "close", "handoff", "none"].some(x => x === nextAction) || !a || !u || !b || ![...a, ...u, ...b].every(x => safeObservationReference(x)) || own(value, "sourceHeadRecheckRequired") !== true || own(value, "currentVerification") !== "not_checked" || own(value, "authorization") !== "none" || own(value, "executable") !== false || own(value, "readOnly") !== true) return;
  if (decision === "handoff_observed" && (!previous || !successor || reasonCode !== "handoff_observed" || previous.workRef.owner !== successor.workRef.owner || previous.workRef.kind !== successor.workRef.kind || previous.workRef.key !== successor.workRef.key || previous.stageId !== successor.stageId || previous.runId === successor.runId || previous.sessionId === successor.sessionId)) return;
  return { previous, successor, decision: decision as WorkHandoff["decision"], reasonCode, nextAction: nextAction as WorkHandoff["nextAction"], acceptedFactRefs: a as string[], unresolvedEffectRefs: u as string[], blockerRefs: b as string[], sourceHeadRecheckRequired: true, currentVerification: "not_checked", authorization: "none", executable: false, readOnly: true };
}
export function emptyGovernance(coverage: GovernanceProjection["coverage"] = "unavailable"): GovernanceProjection {
  return { version: 1, source: "pi.vista", coverage, results: [], handoffs: [], omittedObservations: 0, omittedResults: 0, omittedHandoffs: 0 };
}
export function validGovernanceProjection(value: unknown): value is GovernanceProjection {
  if (own(value, "version") !== 1 || own(value, "source") !== "pi.vista") return false;
  const coverage = own(value, "coverage"), epoch = own(value, "observerEpoch"), seq = own(value, "observerSeq"), at = own(value, "observedAt");
  if (!["not-observed", "not-applicable", "observed", "partial", "unavailable"].some(x => x === coverage)) return false;
  const results = dense(own(value, "results"), 16), handoffs = dense(own(value, "handoffs"), 8), omittedResults = own(value, "omittedResults"), omittedHandoffs = own(value, "omittedHandoffs");
  const omitted = own(value, "omittedObservations");
  if (!results || !handoffs || !uint(omitted) || !uint(omittedResults) || !uint(omittedHandoffs) || !results.every(r => projectOwnerResult(own(r, "observation"))) || !handoffs.every(h => projectWorkHandoff(own(h, "observation")))) return false;
  const entries = [...results, ...handoffs];
  if (!entries.every(r => uint(own(r, "seq")) && Number(own(r, "seq")) > 0 && Number(own(r, "seq")) <= Number(seq) && uint(own(r, "observedAt"), 7_258_118_400_000)) || new Set(entries.map(r => own(r, "seq"))).size !== entries.length) return false;
  if (own(value, "stale") !== undefined && typeof own(value, "stale") !== "boolean") return false;
  if (epoch !== undefined && !safeReference(epoch)) return false;
  if (seq !== undefined && !uint(seq)) return false;
  if (at !== undefined && !uint(at, 7_258_118_400_000)) return false;
  if (coverage === "observed" || coverage === "partial") return epoch !== undefined && seq !== undefined && (coverage === "partial" || (!omitted && !omittedResults && !omittedHandoffs));
  return !results.length && !handoffs.length && !omitted && !omittedResults && !omittedHandoffs;
}
/** Apply only Desk's wire budget. Omit entire observations, not pieces of binding. */
export function boundGovernance(value: GovernanceProjection): GovernanceProjection {
  let size = 0; const results: ObservedResult[] = [], handoffs: ObservedHandoff[] = [];
  for (const r of value.results) { const bytes = Buffer.byteLength(JSON.stringify(r)) + 1; if (size + bytes > 5400) break; results.push(r); size += bytes; }
  for (const h of value.handoffs) { const bytes = Buffer.byteLength(JSON.stringify(h)) + 1; if (size + bytes > 5400) break; handoffs.push(h); size += bytes; }
  const omittedResults = value.omittedResults + value.results.length - results.length, omittedHandoffs = value.omittedHandoffs + value.handoffs.length - handoffs.length;
  return { ...value, results, handoffs, omittedResults, omittedHandoffs, coverage: value.omittedObservations || omittedResults || omittedHandoffs ? "partial" : value.coverage };
}
