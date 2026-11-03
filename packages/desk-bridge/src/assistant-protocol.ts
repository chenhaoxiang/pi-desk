export const assistantLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
export type AssistantTextMessage = { id: string; role: string; text: string };
export type AssistantModelOption = { provider: string; modelId: string; name: string; thinkingLevels: string[] };
export type AssistantSource = { ref: string; title: string; project: string; status: string; tools: string[]; messages: AssistantTextMessage[] };
export type AssistantAnalysis = { overview: string; summaries: { ref: string; text: string }[]; groups: { name: string; refs: string[]; reason: string }[] };
export type AssistantUsage = { input: number; output: number; cacheRead: number; cacheWrite: number };
export type AssistantPayload = {
  operation: string; status?: string; code?: string; provider?: string; modelId?: string; thinking?: string; cancelID?: string;
  models?: AssistantModelOption[]; messages?: AssistantTextMessage[]; revision?: string; partial?: boolean;
  sources?: AssistantSource[]; extra?: string; analysis?: AssistantAnalysis; usage?: AssistantUsage; possibleUsage?: boolean;
};
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const string = (v: unknown, max: number): v is string => typeof v === "string" && Buffer.byteLength(v) <= max;
export const modelPart = (v: unknown): v is string => string(v, 128) && /^[A-Za-z0-9._:/+@-]+$/.test(v);
export const safeGroup = (v: unknown): v is string => string(v, 64) && v.trim().length > 0 && !["未分组", "全部分组", "__none__"].includes(v) && !/[\x00-\x1f\x7f]/.test(v);
export function validAnalysis(v: unknown, refs: Set<string>): v is AssistantAnalysis {
  if (!object(v) || !string(v.overview, 4096) || !v.overview.trim() || !Array.isArray(v.summaries) || v.summaries.length > 8 || !Array.isArray(v.groups) || v.groups.length > 16) return false;
  const summaryRefs = new Set<string>(), grouped = new Set<string>(), names = new Set<string>();
  for (const s of v.summaries) {
    if (!object(s) || !string(s.ref, 16) || !/^[A-Za-z0-9._-]{1,16}$/.test(s.ref) || !refs.has(s.ref) || summaryRefs.has(s.ref) || !string(s.text, 4096) || !s.text.trim()) return false;
    summaryRefs.add(s.ref);
  }
  if (summaryRefs.size !== refs.size) return false;
  for (const g of v.groups) {
    if (!object(g) || !safeGroup(g.name) || names.has(g.name) || !string(g.reason, 1024) || !Array.isArray(g.refs) || !g.refs.length || g.refs.length > 8) return false;
    names.add(g.name);
    for (const ref of g.refs) { if (typeof ref !== "string" || !refs.has(ref) || grouped.has(ref)) return false; grouped.add(ref); }
  }
  return true;
}
const validMessage = (v: unknown): v is AssistantTextMessage => object(v) && string(v.id, 128) && !!v.id && ["user", "assistant"].includes(String(v.role)) && string(v.text, 2048);
export function validAssistant(v: unknown): v is AssistantPayload {
  if (!object(v) || !["models", "context", "analyze", "cancel"].includes(String(v.operation))) return false;
  if (v.status !== undefined && !["ok", "pending", "error", "unknown", "cancelled"].includes(String(v.status))) return false;
  for (const key of ["code", "provider", "modelId", "cancelID", "revision"]) if (v[key] !== undefined && !string(v[key], 128)) return false;
  if (v.thinking !== undefined && !assistantLevels.includes(v.thinking as typeof assistantLevels[number])) return false;
  if (v.extra !== undefined && !string(v.extra, 4096)) return false;
  if (v.partial !== undefined && typeof v.partial !== "boolean") return false;
  if (v.possibleUsage !== undefined && typeof v.possibleUsage !== "boolean") return false;
  if (v.messages !== undefined && (!Array.isArray(v.messages) || v.messages.length > 8 || !v.messages.every(validMessage))) return false;
  if (v.models !== undefined) {
    if (!Array.isArray(v.models) || v.models.length > 128) return false;
    for (const m of v.models) if (!object(m) || !modelPart(m.provider) || !modelPart(m.modelId) || !string(m.name, 64) || !Array.isArray(m.thinkingLevels) || !m.thinkingLevels.length || m.thinkingLevels.length > 7 || !m.thinkingLevels.every((l: unknown) => assistantLevels.includes(l as typeof assistantLevels[number]))) return false;
  }
  if (v.sources !== undefined) {
    if (!Array.isArray(v.sources) || v.sources.length > 8) return false;
    for (const s of v.sources) if (!object(s) || !string(s.ref, 16) || !/^[A-Za-z0-9._-]{1,16}$/.test(s.ref) || !string(s.title, 128) || !string(s.project, 128) || !string(s.status, 128) || !Array.isArray(s.tools) || s.tools.length > 3 || !s.tools.every((t: unknown) => string(t, 128)) || !Array.isArray(s.messages) || s.messages.length > 8 || !s.messages.every(validMessage)) return false;
    if (Buffer.byteLength(JSON.stringify(v.sources)) > 32768) return false;
  }
  if (v.usage !== undefined && (!object(v.usage) || ![v.usage.input, v.usage.output, v.usage.cacheRead, v.usage.cacheWrite].every(n => typeof n === "number" && Number.isSafeInteger(n) && n >= 0 && n <= 9_007_199_254_740_991))) return false;
  if (v.analysis !== undefined) {
    if (!object(v.analysis) || !Array.isArray(v.analysis.summaries)) return false;
    const refs = new Set(v.analysis.summaries.map(s => object(s) ? String(s.ref) : ""));
    if (!validAnalysis(v.analysis, refs)) return false;
  }
  return true;
}

// A conservative preflight, not a claim that arbitrary source text is secret-free.
export function sensitiveText(value: string): boolean {
  return /\bauthorization\s*[:=：]\s*["']?(?:bearer|basic)\s+\S{6,}/i.test(value)
    || /(?:password|passwd|密码)\s*[:=：]\s*["']?[^\s"']{4,}/i.test(value)
    || /\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b/.test(value)
    || /-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----/.test(value)
    || /(?:authorization|api[-_ ]?key|access[-_ ]?token|password|passwd|secret|密码|密钥|令牌)\s*[:=：]\s*["']?[^\s"']{8,}/i.test(value);
}
export function sourceSensitive(sources: AssistantSource[], extra = ""): boolean {
  return sensitiveText(extra) || sources.some(s => [s.title, s.project, s.status, ...s.tools, ...s.messages.map(m => m.text)].some(sensitiveText));
}
