import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { boundGovernance, dense, emptyGovernance, own, projectOwnerResult, projectWorkHandoff, safeReference, uint, type GovernanceProjection } from "./governance-projection.ts";

// Pi Vista owner transport contract v1. This is a read-only memory export,
// not the owner-result request event (which invokes an original reader).
export const WORK_QUERY = "pi-vista:work-observation:query:v1";
export const WORK_REPLY = "pi-vista:work-observation:reply:v1:";
export const WORK_CHANGED = "pi-vista:work-observation:changed:v1";
export function projectWorkSnapshot(raw: unknown, hostSessionId: string): GovernanceProjection | undefined {
  const epoch = own(raw, "observerEpoch"), seq = own(raw, "seq"), coverage = own(raw, "coverage"), omitted = own(raw, "omitted"), entries = dense(own(raw, "observations"), 16);
  if (own(raw, "version") !== 1 || own(raw, "hostSessionId") !== hostSessionId || own(raw, "scope") !== "session-recent-observations" || !safeReference(epoch) || !uint(seq) || !["not-observed", "observed", "not-applicable", "unavailable"].some(x => x === coverage) || !uint(omitted) || !entries || own(raw, "authorization") !== "none" || own(raw, "readOnly") !== true || own(raw, "executable") !== false) return;
  if (coverage !== "observed" && (entries.length || omitted)) return;
  const value: GovernanceProjection = { ...emptyGovernance(coverage as GovernanceProjection["coverage"]), observerEpoch: epoch, observerSeq: seq, omittedObservations: omitted };
  let last = 0;
  for (const entry of entries) {
    const sequence = own(entry, "seq"), observedAt = own(entry, "observedAt"), kind = own(entry, "kind");
    if (!uint(sequence) || sequence <= last || sequence > seq || !uint(observedAt, 7_258_118_400_000)) return;
    last = sequence;
    if (kind === "result") {
      const observation = projectOwnerResult(own(entry, "observation")); if (!observation) return;
      value.results.unshift({ seq: sequence, observedAt, observation });
    } else if (kind === "handoff") {
      const observation = projectWorkHandoff(own(entry, "observation")); if (!observation) return;
      value.handoffs.unshift({ seq: sequence, observedAt, observation });
    } else return;
    value.observedAt = observedAt;
  }
  // An owner's 16-row window may contain 16 handoffs; keep Desk's 8-row limit honest.
  value.omittedHandoffs = Math.max(0, value.handoffs.length - 8); value.handoffs = value.handoffs.slice(0, 8);
  return boundGovernance(value);
}
export class GovernanceClient {
  private value = emptyGovernance("not-observed");
  private closed = false;
  private started = false;
  private off?: () => void;
  private pending?: { id: string; off: () => void; timer: ReturnType<typeof setTimeout>; serial: number; targetEpoch?: string };
  private queued: unknown;
  private scheduled = false;
  private serial = 0;
  private epoch?: string;
  private seq = -1;
  private fingerprint?: string;
  private retired: string[] = [];
  constructor(private events: ExtensionAPI["events"], private hostSessionId: string, private onChange: () => void, private timeoutMs = 400) {}
  read(): GovernanceProjection { return this.value; }
  start() {
    if (this.started || this.closed) return; this.started = true;
    this.off = this.events.on(WORK_CHANGED, payload => {
      if (this.closed || own(payload, "version") !== 1 || own(own(payload, "snapshot"), "hostSessionId") !== this.hostSessionId) return;
      const next = own(payload, "snapshot");
      if (own(this.queued, "observerEpoch") === own(next, "observerEpoch") && uint(own(this.queued, "seq")) && uint(own(next, "seq")) && Number(own(this.queued, "seq")) > Number(own(next, "seq"))) return;
      this.queued = next;
      if (this.scheduled) return; this.scheduled = true;
      setImmediate(() => {
        this.scheduled = false; const raw = this.queued; this.queued = undefined; if (this.closed) return;
        const nextEpoch = own(raw, "observerEpoch");
        if (safeReference(nextEpoch) && nextEpoch !== this.epoch) {
          if (!this.retired.includes(nextEpoch) && this.pending?.targetEpoch !== nextEpoch) { this.finish(); this.refresh(nextEpoch); }
          return;
        }
        this.accept(raw, false);
      }).unref();
    });
    // All session_start handlers get to initialize before the one initial query.
    setImmediate(() => this.refresh()).unref();
  }
  refresh(targetEpoch?: string) {
    if (this.closed || this.pending) return;
    const id = randomUUID(), serial = this.serial;
    const timer = setTimeout(() => { if (this.pending?.id !== id) return; this.finish(); if (serial === this.serial) this.unavailable(); }, this.timeoutMs).unref();
    const off = this.events.on(WORK_REPLY + id, payload => {
      if (this.closed || this.pending?.id !== id || own(payload, "version") !== 1 || own(payload, "requestId") !== id) return;
      const raw = own(payload, "snapshot");
      if (own(raw, "hostSessionId") !== this.hostSessionId) return;
      this.finish(); this.accept(raw, true);
    });
    this.pending = { id, off, timer, serial, targetEpoch };
    try { this.events.emit(WORK_QUERY, { version: 1, requestId: id, hostSessionId: this.hostSessionId }); }
    catch { this.finish(); if (serial === this.serial) this.unavailable(); }
  }
  private accept(raw: unknown, fromQuery: boolean) {
    const projected = projectWorkSnapshot(raw, this.hostSessionId);
    if (!projected) { this.unavailable(); return; }
    const epoch = projected.observerEpoch!, seq = projected.observerSeq!;
    if (this.retired.includes(epoch) || (!fromQuery && epoch !== this.epoch)) return;
    if (epoch === this.epoch && seq < this.seq) return;
    const fingerprint = JSON.stringify(projected);
    if (epoch === this.epoch && seq === this.seq && this.fingerprint !== fingerprint) { this.unavailable(); return; }
    if (epoch !== this.epoch) { if (this.epoch) this.retired = [...this.retired.slice(-7), this.epoch]; this.epoch = epoch; }
    this.seq = seq; this.fingerprint = fingerprint; this.serial++;
    if (JSON.stringify(this.value) !== fingerprint) this.publish(projected);
  }
  private publish(value: GovernanceProjection) { this.value = value; try { this.onChange(); } catch { /* display callbacks cannot affect owner work */ } }
  private unavailable() { this.publish(emptyGovernance()); }
  private finish() { if (this.pending) { clearTimeout(this.pending.timer); this.pending.off(); this.pending = undefined; } }
  close() { this.closed = true; this.finish(); this.off?.(); this.off = undefined; this.queued = undefined; this.value = emptyGovernance(); }
}
