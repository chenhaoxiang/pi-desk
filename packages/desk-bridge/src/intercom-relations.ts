import { types } from "node:util";
import { own } from "./governance-projection.ts";
import { sensitiveText } from "./assistant-protocol.ts";

/** Owner's v1 routing grammar plus Desk's sensitive-value filter; never truncate. */
export const intercomId = (value: unknown): value is string => typeof value === "string"
  && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value) && !value.includes("..") && !sensitiveText(value);

/** Display-only copy of the original broker's relation subset. Routing IDs are
 * not Pi native session ownership, work references or business authorization. */
export type IntercomRelations = {
  version: 1;
  senderSessionId: string;
  recipientSessionId: string;
  supersedes?: string;
  supersededBy?: string;
  replyTo?: string;
  lateReplyTo?: string;
  replyCorrelation: "none" | "matched" | "late" | "unknown";
};
export type IntercomMessageRelations = { messageId: string; relations: IntercomRelations };
const relationKeys = ["supersedes", "supersededBy", "replyTo", "lateReplyTo"] as const;

/** Parse an already-finalized original ToolResult.details, not request arguments
 * or formatted text. A caller must still establish successful current-runtime
 * provenance. Missing/unsupported metadata returns undefined (never "none").
 * No status query, bus handler, persistence, UI or execution is registered here.
 */
export function projectIntercomRelations(details: unknown): IntercomMessageRelations | undefined {
  const messageId = own(details, "messageId"), source = own(details, "relations");
  if (!intercomId(messageId) || !source || typeof source !== "object" || types.isProxy(source)
    || own(details, "error") === true || own(source, "version") !== 1) return;
  const senderSessionId = own(source, "senderSessionId"), recipientSessionId = own(source, "recipientSessionId");
  const correlation = own(source, "replyCorrelation");
  if (!intercomId(senderSessionId) || !intercomId(recipientSessionId)
    || !["none", "matched", "late", "unknown"].some(value => value === correlation)) return;
  const references: Partial<Record<typeof relationKeys[number], string>> = {};
  for (const key of relationKeys) {
    // Absence is allowed; an accessor is not absence and must not be invoked.
    const descriptor = Object.getOwnPropertyDescriptor(source, key);
    if (!descriptor) continue;
    if (!("value" in descriptor)) return;
    const value = descriptor.value;
    if (value === undefined) continue;
    if (!intercomId(value) || value === messageId) return;
    references[key] = value;
  }
  const { replyTo, lateReplyTo } = references;
  if (replyTo && lateReplyTo) return;
  if (correlation === "matched" && !replyTo) return;
  if (correlation === "late" && !lateReplyTo) return;
  if (correlation === "none" && (replyTo || lateReplyTo)) return;
  // unknown may retain an exact original reference. It is not downgraded to
  // none, upgraded to matched, or joined with another reporter's record.
  return {
    messageId,
    relations: {
      version: 1, senderSessionId, recipientSessionId, ...references,
      replyCorrelation: correlation as IntercomRelations["replyCorrelation"],
    },
  };
}
