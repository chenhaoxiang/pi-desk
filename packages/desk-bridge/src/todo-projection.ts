import { createHash, randomUUID } from "node:crypto";
import { types } from "node:util";
import { sensitiveText } from "./assistant-protocol.ts";

export type TodoStatus = "pending" | "in_progress" | "completed";
export type TodoRow = { id: number; subject: string; activeForm?: string; owner?: string; status: TodoStatus; blockedBy: number[]; unresolvedBy: number[]; omittedDependencies: number };
export type TodoProjection = {
  version: 1; source: "pi.todo"; scope: string; observerSeq: number;
  coverage: "not-observed" | "observed" | "partial" | "unavailable";
  observedAt?: number; sourceCall?: string;
  counts?: { pending: number; inProgress: number; completed: number; total: number };
  omitted: number; tasks: TodoRow[];
};
const MAX_TIME = 7_258_118_400_000;
const int = (x: unknown, max = Number.MAX_SAFE_INTEGER): x is number => Number.isSafeInteger(x) && Number(x) >= 0 && Number(x) <= max;
const positive = (x: unknown): x is number => int(x) && x > 0;
const string = (x: unknown, max: number): x is string => typeof x === "string" && Buffer.byteLength(x) <= max;
const token = (x: unknown): x is string => typeof x === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(x);
function own(x: unknown, key: string): unknown {
  if (x === null || typeof x !== "object" || types.isProxy(x)) return undefined;
  const d = Object.getOwnPropertyDescriptor(x, key); return d && "value" in d ? d.value : undefined;
}
function array(x: unknown, max: number): unknown[] | undefined {
  if (!Array.isArray(x) || types.isProxy(x) || !int(x.length, max)) return;
  const values: unknown[] = [];
  for (let i = 0; i < x.length; i++) { const d = Object.getOwnPropertyDescriptor(x, String(i)); if (!d || !("value" in d)) return; values.push(d.value); }
  return values;
}
function safeText(value: unknown, bytes: number): { text?: string; partial: boolean } {
  if (value === undefined) return { partial: false };
  if (typeof value !== "string") return { text: "内容未提供", partial: true };
  // Scan only a bounded prefix. Oversized source is withheld, not partially leaked.
  if (value.length > 2048 || sensitiveText(value) || /(?:^|[\s("'=:])(?:\/(?!\/)\S|~\/|[A-Za-z]:[\\/]|file:\/\/)/.test(value)) return { text: "内容已隐藏", partial: true };
  let output = "", size = 0;
  for (const c of value) {
    const cp = c.codePointAt(0)!;
    const v = cp < 32 || cp === 127 || (cp >= 0xd800 && cp <= 0xdfff) ? " " : c;
    const n = Buffer.byteLength(v); if (size + n > bytes) break; output += v; size += n;
  }
  return { text: output.trim(), partial: output !== value };
}
export function validTodoProjection(x: unknown): x is TodoProjection {
  if (own(x, "version") !== 1 || own(x, "source") !== "pi.todo" || !token(own(x, "scope")) || !int(own(x, "observerSeq"))) return false;
  const coverage = own(x, "coverage"), tasks = array(own(x, "tasks"), 32), counts = own(x, "counts");
  if (typeof coverage !== "string" || !["not-observed", "observed", "partial", "unavailable"].includes(coverage) || !tasks || !int(own(x, "omitted"), 512)) return false;
  if (coverage === "not-observed" || coverage === "unavailable") return tasks.length === 0 && counts === undefined && own(x, "observedAt") === undefined && own(x, "sourceCall") === undefined && own(x, "omitted") === 0;
  if (!int(own(x, "observedAt"), MAX_TIME) || !string(own(x, "sourceCall"), 64) || !/^[a-f0-9]{64}$/.test(String(own(x, "sourceCall")))) return false;
  const numbers = ["pending", "inProgress", "completed", "total"].map(k => own(counts, k));
  if (!numbers.every(n => int(n, 512)) || Number(numbers[0]) + Number(numbers[1]) + Number(numbers[2]) !== numbers[3] || tasks.length + Number(own(x, "omitted")) !== numbers[3]) return false;
  if (coverage === "observed" && own(x, "omitted") !== 0) return false;
  const ids = new Set<number>();
  for (const row of tasks) {
    const id = own(row, "id"), deps = array(own(row, "blockedBy"), 16), unresolved = array(own(row, "unresolvedBy"), 16);
    if (!positive(id) || ids.has(id) || !string(own(row, "subject"), 160) || !String(own(row, "subject")).trim() || !["pending", "in_progress", "completed"].some(status => own(row, "status") === status) || !deps || !unresolved || !int(own(row, "omittedDependencies"), 512)) return false;
    ids.add(id);
    if (["activeForm", "owner"].some(k => own(row, k) !== undefined && !string(own(row, k), k === "owner" ? 80 : 160))) return false;
    if (!deps.every(positive) || new Set(deps).size !== deps.length || !unresolved.every(d => positive(d) && deps.includes(d)) || new Set(unresolved).size !== unresolved.length) return false;
  }
  return true;
}
export class TodoObserver {
  private scope = randomUUID();
  private seq = 0;
  private pending = new Map<string, string>();
  private snapshot: TodoProjection = this.empty("not-observed");
  private empty(coverage: "not-observed" | "unavailable"): TodoProjection {
    return { version: 1, source: "pi.todo", scope: this.scope, observerSeq: this.seq, coverage, omitted: 0, tasks: [] };
  }
  read(): TodoProjection { return this.snapshot; }
  reset() { this.scope = randomUUID(); this.seq++; this.pending.clear(); this.snapshot = this.empty("not-observed"); }
  start(id: string) {
    if (id.length > 512 || this.pending.has(id)) return;
    if (this.pending.size) {
      // Without an owner revision, overlapping result snapshots cannot prove which mutation is latest.
      for (const key of this.pending.keys()) this.pending.set(key, "ambiguous");
      if (this.pending.size < 16) this.pending.set(id, "ambiguous");
      this.seq++; this.snapshot = this.empty("unavailable");
    } else { this.pending.set(id, this.scope); }
  }
  end(id: string, result: unknown, failed: boolean, now: number): boolean {
    const scope = this.pending.get(id); this.pending.delete(id);
    if (scope !== this.scope || failed || own(result, "isError") === true) return false;
    const details = own(result, "details");
    if (own(details, "error") !== undefined) return false;
    const action = own(details, "action"), rows = array(own(details, "tasks"), 512);
    if (typeof action !== "string" || !["create", "update", "get", "list", "delete", "clear"].includes(action) || !rows || !int(now, MAX_TIME)) { this.seq++; this.snapshot = this.empty("unavailable"); return true; }
    if (action === "clear") { this.reset(); if (rows.length) { this.snapshot = this.empty("unavailable"); return true; } }
    const statuses = new Map<number, string>();
    for (const row of rows) {
      const rowId = own(row, "id"), status = own(row, "status");
      if (!positive(rowId) || statuses.has(rowId) || typeof status !== "string" || !["pending", "in_progress", "completed", "deleted"].includes(status)) { this.seq++; this.snapshot = this.empty("unavailable"); return true; }
      statuses.set(rowId, status);
    }
    let partial = false;
    const counts = { pending: 0, inProgress: 0, completed: 0, total: 0 };
    for (const status of statuses.values()) {
      if (status === "deleted") continue;
      counts.total++; if (status === "pending") counts.pending++; else if (status === "in_progress") counts.inProgress++; else counts.completed++;
    }
    // Project text/dependencies only for at most 32 rows, not all 512 owner records.
    const phase = (row: unknown) => own(row, "status") === "in_progress" ? 0 : own(row, "status") === "pending" ? 1 : 2;
    const selected = rows.filter(row => own(row, "status") !== "deleted").sort((a, b) => phase(a) - phase(b) || Number(own(a, "id")) - Number(own(b, "id"))).slice(0, 32);
    const projected: TodoRow[] = [];
    for (const row of selected) {
      const rowId = Number(own(row, "id")), status = statuses.get(rowId)!;
      const rawDeps = own(row, "blockedBy"), deps = rawDeps === undefined ? [] : array(rawDeps, 512);
      if (!deps || !deps.every(positive) || new Set(deps).size !== deps.length) { this.seq++; this.snapshot = this.empty("unavailable"); return true; }
      const subject = safeText(own(row, "subject"), 160), form = safeText(own(row, "activeForm"), 160), owner = safeText(own(row, "owner"), 80);
      const blockedBy = (deps as number[]).slice(0, 16), omittedDependencies = deps.length - blockedBy.length;
      partial ||= !subject.text || subject.partial || form.partial || owner.partial || omittedDependencies > 0;
      projected.push({ id: rowId, subject: subject.text || "未提供任务标题", ...(form.text ? { activeForm: form.text } : {}), ...(owner.text ? { owner: owner.text } : {}), status: status as TodoStatus, blockedBy, unresolvedBy: blockedBy.filter(d => statuses.get(d) !== "completed"), omittedDependencies });
    }
    const rank = (r: TodoRow) => r.status === "in_progress" ? 0 : r.status === "pending" && r.unresolvedBy.length ? 1 : r.status === "pending" ? 2 : 3;
    projected.sort((a, b) => rank(a) - rank(b) || a.id - b.id);
    let size = 0; const tasks: TodoRow[] = [];
    for (const row of projected.slice(0, 32)) { const n = Buffer.byteLength(JSON.stringify(row)) + 1; if (size + n > 7000) break; size += n; tasks.push(row); }
    const omitted = counts.total - tasks.length;
    this.snapshot = { version: 1, source: "pi.todo", scope: this.scope, observerSeq: ++this.seq, coverage: partial || omitted ? "partial" : "observed", observedAt: now, sourceCall: createHash("sha256").update(id).digest("hex"), counts, omitted, tasks };
    return true;
  }
}
