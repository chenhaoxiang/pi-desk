import { randomUUID } from "node:crypto";
import { emptyCodeProgress, projectCodeProgress, type CodeProgressProjection } from "./code-progress.ts";
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
  private progress = emptyCodeProgress("not-observed");
  private closed = false;
  private started = false;
  private off?: () => void;
  private pending?: { id: string; off: () => void; timer: ReturnType<typeof setTimeout>; serial: number; targetEpoch?: string };
  private queued: unknown;
  private queuedProgress: unknown;
  private progressNotice?: { epoch: string; seq: number; fingerprint: string };
  private queuedProgressConflict?: { epoch: string; seq: number };
  private scheduled = false;
  private serial = 0;
  private epoch?: string;
  private seq = -1;
  private fingerprint?: string;
  private progressSeq = -1;
  private progressFingerprint?: string;
  private progressConflict = false;
  private retired: string[] = [];
  constructor(private events: ExtensionAPI["events"], private hostSessionId: string, private onChange: () => void, private timeoutMs = 400) {}
  read(): GovernanceProjection { return this.value; }
  readCodeProgress(): CodeProgressProjection { return this.progress; }
  start() {
    if (this.started || this.closed) return; this.started = true;
    this.off = this.events.on(WORK_CHANGED, payload => {
      if (this.closed || own(payload,"version") !== 1 || own(own(payload,"snapshot"),"hostSessionId") !== this.hostSessionId) return;
      const next = own(payload,"snapshot"), epoch = own(next,"observerEpoch");
      this.noteProgress(next);
      const newer = (queued: unknown, oldSeq: unknown, newSeq: unknown) => own(queued,"observerEpoch") !== epoch || !uint(oldSeq) || !uint(newSeq) || newSeq >= oldSeq;
      // Two bounded slots: coalescing one lane must not discard a newer other
      // lane merely because their independent sequences advance differently.
      if (newer(this.queued,own(this.queued,"seq"),own(next,"seq"))) this.queued = next;
      if (newer(this.queuedProgress,own(own(this.queuedProgress,"codeProgress"),"seq"),own(own(next,"codeProgress"),"seq"))) this.queuedProgress = next;
      if (this.scheduled) return; this.scheduled = true;
      setImmediate(() => {
        this.scheduled = false;
        const raw = this.queued, progressRaw = this.queuedProgress;
        this.queued = undefined; this.queuedProgress = undefined;
        if (this.closed) return;
        for (const value of raw === progressRaw ? [raw] : [raw,progressRaw]) {
          const nextEpoch = own(value,"observerEpoch");
          if (safeReference(nextEpoch) && nextEpoch !== this.epoch) {
            if (!this.retired.includes(nextEpoch) && this.pending?.targetEpoch !== nextEpoch) { this.finish(); this.refresh(nextEpoch); }
            continue;
          }
          this.accept(value,false);
        }
      }).unref();
    });
    setImmediate(() => this.refresh()).unref();
  }
  refresh(targetEpoch?: string) {
    if (this.closed || this.pending) return;
    const id = randomUUID(), serial = this.serial;
    const timer = setTimeout(() => { if (this.pending?.id !== id) return; this.finish(); if (serial === this.serial) this.unavailable(true); },this.timeoutMs).unref();
    const off = this.events.on(WORK_REPLY + id,payload => {
      if (this.closed || this.pending?.id !== id || own(payload,"version") !== 1 || own(payload,"requestId") !== id) return;
      const raw = own(payload,"snapshot");
      if (own(raw,"hostSessionId") !== this.hostSessionId) return;
      this.finish(); this.accept(raw,true);
    });
    this.pending = {id,off,timer,serial,targetEpoch};
    try { this.events.emit(WORK_QUERY,{version:1,requestId:id,hostSessionId:this.hostSessionId}); }
    catch { this.finish(); if (serial === this.serial) this.unavailable(true); }
  }
  private markProgressConflict(epoch: string, seq: number) {
    const previous = this.queuedProgressConflict;
    if (!previous || previous.epoch !== epoch || seq > previous.seq) this.queuedProgressConflict = {epoch,seq};
  }
  private noteProgress(raw: unknown) {
    const epoch = own(raw,"observerEpoch");
    if (!safeReference(epoch) || this.retired.includes(epoch) || own(raw,"version") !== 1 || own(raw,"hostSessionId") !== this.hostSessionId
      || own(raw,"scope") !== "session-recent-observations" || own(raw,"authorization") !== "none" || own(raw,"readOnly") !== true || own(raw,"executable") !== false) return;
    const progress = projectCodeProgress(own(raw,"codeProgress"),epoch);
    if (!progress || (epoch === this.epoch && progress.seq < this.progressSeq)) return;
    const fingerprint = JSON.stringify(progress), previous = this.progressNotice;
    // Snapshot only the bounded projected fingerprint, not raw content. One
    // highest-sequence notice and one conflict watermark survive last-wins
    // coalescing; a third copy cannot hide a middle equal-sequence conflict.
    if ((previous?.epoch === epoch && previous.seq === progress.seq && previous.fingerprint !== fingerprint)
      || (epoch === this.epoch && progress.seq === this.progressSeq && this.progressFingerprint !== undefined && this.progressFingerprint !== fingerprint)) this.markProgressConflict(epoch,progress.seq);
    if (!previous || previous.epoch !== epoch || progress.seq >= previous.seq) this.progressNotice = {epoch,seq:progress.seq,fingerprint};
  }
  private accept(raw: unknown, fromQuery: boolean) {
    const epoch = own(raw,"observerEpoch");
    if (own(raw,"version") !== 1 || own(raw,"hostSessionId") !== this.hostSessionId || !safeReference(epoch)
      || own(raw,"scope") !== "session-recent-observations" || own(raw,"authorization") !== "none" || own(raw,"readOnly") !== true || own(raw,"executable") !== false) { this.unavailable(); return; }
    if (this.retired.includes(epoch) || (!fromQuery && epoch !== this.epoch)) return;
    const previousValue = this.value, previousProgress = this.progress;
    const projected = projectWorkSnapshot(raw,this.hostSessionId);
    const progress = projectCodeProgress(own(raw,"codeProgress"),epoch);
    if (!projected && !progress) { this.value = emptyGovernance(); this.progressUnavailable(); this.notify(); return; }
    if (epoch !== this.epoch) {
      if (this.epoch) this.retired = [...this.retired.slice(-7),this.epoch];
      this.epoch = epoch; this.seq = -1; this.fingerprint = undefined;
      this.progressSeq = -1; this.progressFingerprint = undefined; this.progressConflict = false;
      if (this.progressNotice?.epoch !== epoch) this.progressNotice = undefined;
      if (this.queuedProgressConflict?.epoch !== epoch) this.queuedProgressConflict = undefined;
      this.value = emptyGovernance("not-observed"); this.progress = emptyCodeProgress("not-observed");
    }
    if (!projected) this.value = emptyGovernance();
    else if (projected.observerSeq! >= this.seq) {
      // This fingerprint contains only original v1 result/handoff fields.
      const fingerprint = JSON.stringify(projected);
      if (projected.observerSeq === this.seq && this.fingerprint !== fingerprint) this.value = emptyGovernance();
      else {
        this.seq = projected.observerSeq!; this.fingerprint = fingerprint;
        if (JSON.stringify(this.value) !== fingerprint) this.value = projected;
      }
    }
    // Also catch a changed mutable payload between notification and flush.
    if (progress && this.progressNotice?.epoch === epoch && this.progressNotice.seq === progress.seq && this.progressNotice.fingerprint !== JSON.stringify(progress)) this.markProgressConflict(epoch,progress.seq);
    const conflict = this.queuedProgressConflict;
    if (conflict?.epoch === epoch && conflict.seq >= this.progressSeq && (!progress || progress.seq <= conflict.seq)) {
      this.progressSeq = Math.max(this.progressSeq,conflict.seq); this.progressConflict = true; this.progressUnavailable();
    } else if (!progress) this.progressUnavailable();
    else if (progress.seq >= this.progressSeq) {
      const fingerprint = JSON.stringify(progress);
      if (progress.seq === this.progressSeq && (this.progressConflict || this.progressFingerprint !== fingerprint)) {
        this.progressConflict = true; this.progressUnavailable();
      } else {
        this.progressSeq = progress.seq; this.progressFingerprint = fingerprint; this.progressConflict = false;
        if (this.queuedProgressConflict?.epoch === epoch && progress.seq > this.queuedProgressConflict.seq) this.queuedProgressConflict = undefined;
        if (JSON.stringify(this.progress) !== fingerprint) this.progress = progress;
      }
    }
    if (projected || progress) this.serial++;
    if (previousValue !== this.value || previousProgress !== this.progress) this.notify();
  }
  private notify() { try { this.onChange(); } catch { /* display cannot affect owner work */ } }
  private progressUnavailable() {
    const next = this.progress.observations.length ? {...this.progress,stale:true} : emptyCodeProgress();
    if (JSON.stringify(this.progress) !== JSON.stringify(next)) this.progress = next;
  }
  private unavailable(preserve = false) {
    this.value = preserve && (this.value.results.length || this.value.handoffs.length) ? {...this.value,stale:true} : emptyGovernance();
    if (preserve) this.progressUnavailable(); else this.progress = emptyCodeProgress();
    this.notify();
  }
  private finish() { if (this.pending) { clearTimeout(this.pending.timer); this.pending.off(); this.pending = undefined; } }
  close() { this.closed = true; this.finish(); this.off?.(); this.off = undefined; this.queued = undefined; this.queuedProgress = undefined; this.progressNotice = undefined; this.queuedProgressConflict = undefined; this.value = emptyGovernance(); this.progress = emptyCodeProgress(); }
}
