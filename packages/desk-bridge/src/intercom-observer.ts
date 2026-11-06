import { randomUUID } from "node:crypto";
import { dense, own, safeReference, uint } from "./governance-projection.ts";
import { intercomId, projectIntercomRelations, type IntercomRelations } from "./intercom-relations.ts";

export type IntercomStatusView = {
  messageId: string; observedAt: number; sourceUpdatedAt?: number;
  coverage: "observed" | "unavailable"; reason?: string;
  delivery?: "socket_delivered" | "queued" | "failed" | "unknown";
  replyState?: "not_requested" | "pending" | "answered" | "expired" | "unknown";
  outcomeKnown?: boolean; relations?: IntercomRelations;
};
export type IntercomRelationsProjection = {
  version: 1; source: "pi.intercom.status"; scope: string; observerSeq: number;
  coverage: "not-observed" | "observed" | "partial";
  records: IntercomStatusView[]; omitted: number; evictedRecords: number;
};
const MAX_TIME = 7_258_118_400_000;
const deliveries = ["socket_delivered", "queued", "failed", "unknown"];
const replies = ["not_requested", "pending", "answered", "expired", "unknown"];
const absent = (messageId: string, observedAt: number, reason: string, sourceUpdatedAt?: number): IntercomStatusView => ({
  messageId, observedAt, ...(sourceUpdatedAt === undefined ? {} : { sourceUpdatedAt }), coverage: "unavailable", reason,
});
function project(details: unknown, messageId: string, now: number): IntercomStatusView {
  const rawTime = own(details, "updatedAt"), time = uint(rawTime, MAX_TIME) ? rawTime : undefined;
  const fail = (reason: string) => absent(messageId, now, reason, time);
  if (own(details, "error") === true || own(details, "messageId") !== messageId) return fail("source-invalid");
  const relation = projectIntercomRelations(details), delivery = own(details, "delivery"), replyState = own(details, "replyState"), known = own(details, "outcomeKnown");
  if (!relation) return fail("relations-unavailable");
  if (time === undefined || !deliveries.some(x => x === delivery) || !replies.some(x => x === replyState)
    || typeof known !== "boolean" || known !== (delivery !== "unknown")
    || own(details, "execution") !== "unknown" || own(details, "completion") !== "unknown"
    || (delivery === "unknown" && relation.relations.replyCorrelation !== "unknown")) return fail("source-invalid");
  return { messageId, observedAt: now, sourceUpdatedAt: time, coverage: "observed", delivery: delivery as IntercomStatusView["delivery"], replyState: replyState as IntercomStatusView["replyState"], outcomeKnown: known, relations: relation.relations };
}
const fingerprint = (record: IntercomStatusView) => JSON.stringify({ ...record, observedAt: 0 });

/** Only finalized successful native status results. No Intercom client, query,
 * message body, history, mutation, human alert or cross-reporter graph. */
export class IntercomRelationsObserver {
  private scope = randomUUID(); private seq = 0; private evicted = 0;
  private calls = new Map<string, { scope: string; record?: IntercomStatusView }>();
  private latest = new Map<string, { time?: number; conflict: boolean; record: IntercomStatusView }>();
  read(): IntercomRelationsProjection {
    const records: IntercomStatusView[] = []; let bytes = 0;
    for (const { record } of this.latest.values()) {
      const size = Buffer.byteLength(JSON.stringify(record)) + 1;
      if (bytes + size > 5400) break;
      records.push(record); bytes += size;
    }
    const omitted = this.latest.size - records.length;
    return { version: 1, source: "pi.intercom.status", scope: this.scope, observerSeq: this.seq,
      coverage: !this.latest.size ? "not-observed" : omitted || this.evicted || records.some(r => r.coverage !== "observed") ? "partial" : "observed",
      records, omitted, evictedRecords: this.evicted };
  }
  reset() { this.scope = randomUUID(); this.seq++; this.evicted = 0; this.calls.clear(); this.latest.clear(); }
  start(id: string) { if (typeof id === "string" && id.length <= 512 && this.calls.size < 32 && !this.calls.has(id)) this.calls.set(id, { scope: this.scope }); }
  result(event: unknown) {
    const id = own(event, "toolCallId"), call = typeof id === "string" ? this.calls.get(id) : undefined;
    if (!call || call.scope !== this.scope || own(event, "toolName") !== "intercom" || own(event, "isError") !== false) return;
    const input = own(event, "input"), messageId = own(input, "messageId");
    if (own(input, "action") !== "status" || !intercomId(messageId)) return;
    const details = own(event, "details");
    if (own(details, "error") === true || own(details, "messageId") !== messageId) return;
    call.record = project(details, messageId, 0);
  }
  end(id: string, result: unknown, failed: boolean, now: number): boolean {
    const call = this.calls.get(id); this.calls.delete(id);
    if (!call?.record || call.scope !== this.scope || failed || own(result, "isError") === true || !uint(now, MAX_TIME)) return false;
    const details = own(result, "details");
    if (own(details, "error") === true) return false;
    const first = call.record, final = project(details, first.messageId, now);
    const record = fingerprint(first) === fingerprint(final) ? final : absent(first.messageId, now, "finalized-mismatch", first.sourceUpdatedAt);
    const previous = this.latest.get(record.messageId), time = record.sourceUpdatedAt;
    if (previous?.time !== undefined && time !== undefined && time < previous.time) return false;
    if (previous && previous.time === time) {
      if (previous.conflict || fingerprint(previous.record) === fingerprint(record)) return false;
      this.latest.set(record.messageId, { time, conflict: true, record: absent(record.messageId, now, "same-time-conflict", time) });
    } else {
      if (previous?.conflict && (time === undefined || time <= previous.time!)) return false;
      this.latest.set(record.messageId, { time: time ?? previous?.time, conflict: false, record });
    }
    if (this.latest.size > 16) { this.latest.delete(this.latest.keys().next().value!); this.evicted++; }
    this.seq++; return true;
  }
}
export function validIntercomRelations(value: unknown): value is IntercomRelationsProjection {
  const records = dense(own(value, "records"), 16), coverage = own(value, "coverage"), omitted = own(value, "omitted"), evicted = own(value, "evictedRecords");
  if (own(value, "version") !== 1 || own(value, "source") !== "pi.intercom.status" || !safeReference(own(value, "scope")) || !uint(own(value, "observerSeq"))
    || !records || !uint(omitted, 16) || !uint(evicted) || !["not-observed", "observed", "partial"].some(x => x === coverage)) return false;
  if (coverage === "not-observed") return !records.length && omitted === 0 && evicted === 0;
  const ids = new Set<string>();
  for (const record of records) {
    const id = own(record, "messageId"), time = own(record, "sourceUpdatedAt");
    if (!intercomId(id) || ids.has(id) || !uint(own(record, "observedAt"), MAX_TIME) || (time !== undefined && !uint(time, MAX_TIME))) return false;
    ids.add(id);
    if (own(record, "coverage") === "unavailable") {
      if (!safeReference(own(record, "reason")) || ["relations", "delivery", "replyState", "outcomeKnown"].some(k => own(record, k) !== undefined)) return false;
    } else {
      if (own(record, "coverage") !== "observed" || own(record, "reason") !== undefined) return false;
      const projected = project({ messageId: id, updatedAt: time, relations: own(record, "relations"), delivery: own(record, "delivery"), replyState: own(record, "replyState"), outcomeKnown: own(record, "outcomeKnown"), execution: "unknown", completion: "unknown" }, id, 0);
      if (projected.coverage !== "observed") return false;
    }
  }
  return coverage !== "observed" || (omitted === 0 && evicted === 0 && records.every(r => own(r, "coverage") === "observed"));
}
