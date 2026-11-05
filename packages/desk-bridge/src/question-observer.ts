import { createHash } from "node:crypto";
import { own, projectWorkRef, safeReference, uint } from "./governance-projection.ts";
import type { InputNotice } from "./protocol.ts";
import { knownQuestionCredential, type QuestionWorkLink } from "./question-projection.ts";

export const WORK_QUESTION_EVENT = "pi:work-question:v1";
// Native composite call IDs are opaque. Only a digest crosses the Desk wire;
// source callbacks always correlate by the unchanged full original string.
function callID(raw: unknown): string | undefined {
  return typeof raw === "string" && raw.length > 0 && Buffer.byteLength(raw) <= 512 && /^[A-Za-z0-9._:/|-]+$/.test(raw) ? raw : undefined;
}
function ownerCallID(raw: unknown): string | undefined {
  const value = callID(raw);
  return value && /^[A-Za-z0-9_.:|_-]+(?:\/[1-9][0-9]*)*$/.test(value) && ![".", ".."].includes(value.split("/")[0]) && !/^[A-Za-z]:\//.test(value) && !knownQuestionCredential(value) ? value : undefined;
}
function inputID(raw: string): string { return "question-" + createHash("sha256").update(raw).digest("hex"); }
type Seen = { phase: "opened" | "answer-received" | "closed"; epoch: string; sequence: number };
/** Bounded transient input projection. No owner store, history read, answer
 * method or inference from idle/UNKNOWN is added. v1 remains independently usable. */
export class QuestionObserver {
  private epoch?: string;
  private sequence = -1;
  private retired: string[] = [];
  private seen = new Map<string, Seen>();
  constructor(private hostSessionId: string, private inputs: Map<string, InputNotice>, private now: () => number) {}
  legacy(raw: unknown): boolean {
    const rawCall = own(raw, "id"), phase = own(raw, "phase");
    const call = typeof rawCall === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(rawCall) ? rawCall : ownerCallID(rawCall);
    if (own(raw, "version") !== 1 || own(raw, "source") !== "ask_user_question" || !call || (phase !== "start" && phase !== "end")) return false;
    const id = inputID(call), linked = this.seen.get(id);
    // The existing UI end remains authoritative even if optional work metadata
    // is malformed or dropped. v1 has no epoch; do not invent such provenance.
    if (phase === "end") {
      if (linked) this.seen.set(id, { ...linked, phase: "closed" });
      return this.inputs.delete(id);
    }
    if (linked) return false;
    if (this.inputs.has(id) || this.inputs.size >= 32) return false;
    this.inputs.set(id, { id, source: "pi:input-required", kind: "question", startedAt: this.now() }); return true;
  }
  observe(raw: unknown): boolean {
    const call = ownerCallID(own(raw, "toolCallId")), epoch = own(raw, "epoch"), sequence = own(raw, "seq"), phase = own(raw, "phase"), observedAt = own(raw, "observedAt"), reason = own(raw, "closeReason");
    if (own(raw, "version") !== 1 || own(raw, "source") !== "ask_user_question" || own(raw, "sessionId") !== this.hostSessionId || !call || !safeReference(epoch) || knownQuestionCredential(epoch) || !uint(sequence) || sequence < 1 || !uint(observedAt, 7_258_118_400_000) || !["opened", "answer-received", "closed"].some(x => x === phase)) return false;
    if (phase === "closed" ? !["answered", "declined", "aborted", "error", "chat", "empty"].some(x => x === reason) : reason !== null) return false;
    if (this.retired.includes(epoch) || (epoch === this.epoch && sequence <= this.sequence)) return false;
    // A terminal event alone cannot establish a new producer instance/active UI.
    if (epoch !== this.epoch) {
      if (phase !== "opened") return false;
      if (this.epoch) {
        this.retired = [...this.retired.slice(-7), this.epoch];
        for (const [id, input] of this.inputs) if (input.source === "pi:input-required") this.inputs.delete(id);
      }
      this.seen.clear(); this.epoch = epoch; this.sequence = -1;
    }
    this.sequence = sequence;
    const id = inputID(call);
    this.seen.set(id, { phase: phase as Seen["phase"], epoch, sequence });
    while (this.seen.size > 128) {
      const old = [...this.seen].find(([, value]) => value.phase !== "opened");
      if (!old) { this.seen.delete(id); break; }
      this.seen.delete(old[0]);
    }
    if (phase !== "opened") return this.inputs.delete(id);
    const association = own(raw, "workAssociation"), workRef = projectWorkRef(own(raw, "workRef")), stageId = own(raw, "stageId");
    const declared = association === "declared" && !!workRef && !knownQuestionCredential(workRef.owner) && !knownQuestionCredential(workRef.key) && (stageId === null || (safeReference(stageId) && !knownQuestionCredential(stageId)));
    const unbound = association === "unbound" && own(raw, "workRef") === null && stageId === null;
    const question: QuestionWorkLink = { version: 1, ownerEpoch: epoch, sequence, observedAt,
      binding: declared ? "declared" : unbound ? "unbound" : "unavailable",
      ...(declared ? { workRef, ...(typeof stageId === "string" ? { workPhase: stageId } : {}) } : {}),
    };
    const existing = this.inputs.get(id);
    if (!existing && this.inputs.size >= 32) return false;
    this.inputs.set(id, { id, source: "pi:input-required", kind: "question", startedAt: existing?.startedAt ?? observedAt, question });
    return true;
  }
  close() { this.seen.clear(); this.retired = []; this.epoch = undefined; this.sequence = -1; }
}
