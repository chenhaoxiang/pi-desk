import { own, projectWorkRef, safeReference, uint, type WorkRef } from "./governance-projection.ts";

/** Optional display attachment to the existing InputNotice, not a question DB,
 * answer endpoint, or authority over whether a decision has been applied. */
export type QuestionWorkLink = {
  version: 1;
  binding: "declared" | "unbound" | "unavailable";
  workRef?: WorkRef;
  workPhase?: string;
  ownerEpoch: string;
  sequence: number;
  observedAt: number;
};
export const knownQuestionCredential = (value: unknown): boolean => typeof value === "string" && /(?:github_pat_[A-Za-z0-9_]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/iu.test(value);
export function validQuestionWorkLink(value: unknown): value is QuestionWorkLink {
  const binding = own(value, "binding"), work = own(value, "workRef"), phase = own(value, "workPhase");
  if (own(value, "version") !== 1 || !["declared", "unbound", "unavailable"].some(x => x === binding) || !safeReference(own(value, "ownerEpoch")) || knownQuestionCredential(own(value, "ownerEpoch")) || !uint(own(value, "sequence")) || !uint(own(value, "observedAt"), 7_258_118_400_000)) return false;
  if (binding === "declared") {
    const ref = projectWorkRef(work);
    return !!ref && !knownQuestionCredential(ref.owner) && !knownQuestionCredential(ref.key) && (phase === undefined || (safeReference(phase) && !knownQuestionCredential(phase)));
  }
  return work === undefined && phase === undefined;
}
