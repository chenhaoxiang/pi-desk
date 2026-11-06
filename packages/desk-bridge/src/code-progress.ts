import { types } from "node:util";
import { dense, own, projectWorkBinding, safeReference, uint, type WorkBinding } from "./governance-projection.ts";

/** Exact producer triples. Progress is never an acceptance or execution receipt. */
export const CODE_PROGRESS_STATES = [
  ["pull-request", "pr_not_ready", "follow_owner_work"],
  ["head-checks", "required_checks_pending", "wait_required_checks"],
  ["head-checks", "required_checks_failed", "inspect_required_checks"],
  ["head-checks", "required_checks_missing", "inspect_required_evidence"],
  ["owner-gate", "owner_delivery_pending", "follow_owner_delivery"],
  ["postmerge-checks", "postmerge_workflows_pending", "wait_postmerge_checks"],
  ["postmerge-checks", "postmerge_workflows_failed", "inspect_postmerge_checks"],
  ["postmerge-checks", "postmerge_workflows_missing", "inspect_required_evidence"],
  ["owner-gate", "owner_gate_unavailable", "inspect_owner_evidence"],
  ["source-delivery", "none", "inspect_result"],
  ["unknown", "source_binding_mismatch", "inspect_binding"],
  ["unknown", "source_original_unavailable", "inspect_originals"],
] as const;
export type CodeProgressRow = {
  seq: number; binding: WorkBinding; repository: string; pullRequest: number; observedAt: number;
  phase: string; waitReason: string; nextAction: string;
  authorization: "none"; readOnly: true; executable: false;
};
export type CodeProgressProjection = {
  version: 1; source: "explicit-code-owner"; seq: number;
  coverage: "not-observed" | "observed" | "not-applicable" | "unavailable";
  observations: CodeProgressRow[]; omitted: number;
  /** The containing native observer epoch; not a second producer authority. */
  observerEpoch?: string; stale?: boolean;
};
const MAX_TIME = 7_258_118_400_000;
const rowKeys = ["seq", "binding", "repository", "pullRequest", "observedAt", "phase", "waitReason", "nextAction", "authorization", "readOnly", "executable"];
function closed(value: unknown, keys: string[]): boolean {
  if (!value || typeof value !== "object" || types.isProxy(value) || Object.getPrototypeOf(value) !== Object.prototype) return false;
  const names = Reflect.ownKeys(value);
  return names.length <= keys.length && names.every(key => typeof key === "string" && keys.includes(key) && Object.hasOwn(Object.getOwnPropertyDescriptor(value,key)!, "value"));
}
export function codeRepository(value: unknown): value is string {
  return typeof value === "string" && value.length <= 200 && /^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(value)
    && value.split("/").every(part => safeReference(part, 200));
}
export function projectCodeProgressRow(value: unknown): CodeProgressRow | undefined {
  if (!closed(value, rowKeys)) return;
  const binding = projectWorkBinding(own(value,"binding")), seq = own(value,"seq"), repository = own(value,"repository"), pullRequest = own(value,"pullRequest"), observedAt = own(value,"observedAt");
  const phase = own(value,"phase"), waitReason = own(value,"waitReason"), nextAction = own(value,"nextAction");
  if (!binding?.headSha || !uint(seq) || seq < 1 || !codeRepository(repository) || !uint(pullRequest) || pullRequest < 1 || !uint(observedAt,MAX_TIME)
    || !CODE_PROGRESS_STATES.some(([p,r,n]) => p === phase && r === waitReason && n === nextAction)
    || own(value,"authorization") !== "none" || own(value,"readOnly") !== true || own(value,"executable") !== false) return;
  return { seq, binding, repository, pullRequest, observedAt, phase: phase as string, waitReason: waitReason as string, nextAction: nextAction as string, authorization:"none",readOnly:true,executable:false };
}
export function emptyCodeProgress(coverage: CodeProgressProjection["coverage"] = "unavailable"): CodeProgressProjection {
  return { version:1,source:"explicit-code-owner",seq:0,coverage,observations:[],omitted:0 };
}
/** Optional producer sidecar. Reject only this lane on malformed/oversized input. */
export function projectCodeProgress(value: unknown, observerEpoch: string): CodeProgressProjection | undefined {
  if (!safeReference(observerEpoch) || !closed(value,["version","source","seq","coverage","observations","omitted"])) return;
  const seq = own(value,"seq"), coverage = own(value,"coverage"), entries = dense(own(value,"observations"),16), omitted = own(value,"omitted");
  if (own(value,"version") !== 1 || own(value,"source") !== "explicit-code-owner" || !uint(seq) || !uint(omitted) || !entries
    || !["not-observed","observed","not-applicable","unavailable"].some(x => x === coverage)) return;
  if ((coverage === "not-observed" || coverage === "not-applicable") && (entries.length || omitted)) return;
  const observations: CodeProgressRow[] = []; let previous = 0;
  for (const entry of entries) {
    const row = projectCodeProgressRow(entry);
    if (!row || row.seq <= previous || row.seq > seq) return;
    observations.push(row); previous = row.seq;
  }
  const projected = {version:1 as const,source:"explicit-code-owner" as const,seq,coverage:coverage as CodeProgressProjection["coverage"],observations,omitted};
  // Serialize only the newly projected scalars, never raw metadata or a toJSON hook.
  if (Buffer.byteLength(JSON.stringify(projected)) > 5400) return;
  return {...projected,observerEpoch,...(coverage === "unavailable" && observations.length ? {stale:true} : {})};
}
export function validCodeProgress(value: unknown): value is CodeProgressProjection {
  const epoch = own(value,"observerEpoch"), stale = own(value,"stale");
  if ((epoch !== undefined && !safeReference(epoch)) || (stale !== undefined && typeof stale !== "boolean")) return false;
  const projected = projectCodeProgress({version:own(value,"version"),source:own(value,"source"),seq:own(value,"seq"),coverage:own(value,"coverage"),observations:own(value,"observations"),omitted:own(value,"omitted")}, typeof epoch === "string" ? epoch : "unavailable");
  return !!projected && ((projected.coverage !== "observed" && !projected.observations.length) || epoch !== undefined);
}
