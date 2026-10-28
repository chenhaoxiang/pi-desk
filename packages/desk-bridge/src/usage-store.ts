import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, link, unlink, rename } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { object, safeId, type Identity, type Tokens } from "./protocol.ts";
import { tokens } from "./usage.ts";

const hash = (s: string) => createHash("sha256").update(s).digest("hex");
const fields = ["input", "output", "cacheRead", "cacheWrite"] as const;
const reasons = new Set([
  "missing-usage", "missing-receipt", "invalid-time", "tool-usage-unattributed",
  "boundary-usage-not-covered", "queue-full", "write-failed", "receipt-conflict",
  "observation-fault", "storage-capacity", "auxiliary-usage-not-covered", "close-flush-unconfirmed",
]);
export type UsageEntry = {
  version: 1; kind: "usage"; id: string; session: string; occurredAt: number;
  model: string; source: "pi.assistant.final"; tokens: Tokens;
};
export type RecorderState = {
  version: 1; kind: "recorder"; id: string; session: string;
  startedAt: number; updatedAt: number; lastSuccessAt: number | null;
  accepted: number; dropped: number; pending: number; writeFailures: number;
  closed: boolean; reasons: string[];
};
export function usageRoot(): string {
  // Explicit test socket opts into an isolated sibling store, never the user's ledger.
  return process.env.PI_DESK_USAGE_DIR ?? (process.env.PI_DESK_SOCKET
    ? join(dirname(process.env.PI_DESK_SOCKET), "usage-v1")
    : join(homedir(), "Library/Application Support/PiDesk/usage-v1"));
}
export function usageEntry(identity: Identity, receipt: unknown, message: unknown, now: number): UsageEntry | undefined {
  if (!safeId(receipt) || !object(message) || message.role !== "assistant" ||
    !["stop", "length", "toolUse", "error", "aborted"].includes(String(message.stopReason))) return;
  const time = message.timestamp;
  if (typeof time !== "number" || !Number.isSafeInteger(time) || time < 946684800000 || time > now) return;
  if (typeof message.provider !== "string" || typeof message.model !== "string") return;
  const model = message.provider + "/" + message.model;
  if (!/^[A-Za-z0-9._:/+@ -]{1,128}$/.test(model)) return;
  const session = hash(identity.localHostId + ":" + identity.nativeSessionId);
  return { version: 1, kind: "usage", id: hash(session + ":" + receipt), session,
    occurredAt: time, model, source: "pi.assistant.final", tokens: tokens(message.usage) };
}
export function validUsage(v: unknown): v is UsageEntry {
  if (!object(v) || !object(v.tokens)) return false;
  const t = v.tokens;
  return Object.keys(v).sort().join(",") === "id,kind,model,occurredAt,session,source,tokens,version" &&
    v.version === 1 && v.kind === "usage" && /^[a-f0-9]{64}$/.test(String(v.id)) &&
    /^[a-f0-9]{64}$/.test(String(v.session)) && v.source === "pi.assistant.final" &&
    typeof v.model === "string" && /^[A-Za-z0-9._:/+@ -]{1,128}$/.test(v.model) &&
    typeof v.occurredAt === "number" && Number.isSafeInteger(v.occurredAt) && v.occurredAt >= 946684800000 &&
    Object.keys(t).sort().join(",") === "cacheRead,cacheWrite,input,output" &&
    fields.every(k => t[k] === null || (Number.isSafeInteger(t[k]) && Number(t[k]) >= 0));
}
export async function privateDirectory(path: string): Promise<void> {
  if (!path.startsWith("/") || resolve(path) !== path) throw Error("unsafe-usage-path");
  let current = "/";
  for (const part of path.split("/").filter(Boolean)) {
    current = join(current, part);
    try { await mkdir(current, { mode: 0o700 }); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e; }
    const s = await lstat(current);
    if (!s.isDirectory() || s.isSymbolicLink()) throw Error("unsafe-usage-directory");
  }
  const s = await lstat(path);
  if (s.uid !== process.getuid?.() || (s.mode & 0o077) !== 0) throw Error("unsafe-usage-directory");
}
async function readPrivate(path: string): Promise<string> {
  const f = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const s = await f.stat();
    if (!s.isFile() || s.uid !== process.getuid?.() || (s.mode & 0o077) !== 0 || s.nlink !== 1 || s.size > 4096) throw Error("unsafe-usage-file");
    return await f.readFile("utf8");
  } finally { await f.close(); }
}
async function atomic(path: string, data: string, replace: boolean): Promise<void> {
  const temporary = join(dirname(path), ".usage-" + randomUUID());
  const f = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
  try {
    await f.writeFile(data); await f.sync(); await f.close();
    if (replace) {
      try { await readPrivate(path); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
      await rename(temporary, path);
    } else {
      try { await link(temporary, path); }
      catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
        if (await readPrivate(path) !== data) throw Error("receipt-conflict");
      }
    }
    // Persist the directory rename/link as well as file bytes when supported.
    const d = await open(dirname(path), constants.O_RDONLY);
    try { await d.sync(); } finally { await d.close(); }
  } finally { await f.close().catch(() => {}); await unlink(temporary).catch(() => {}); }
}
export type UsageWriterOptions = {
  root?: string; now?: () => number; maximumQueue?: number; maximumShardFiles?: number;
  write?: (entry: UsageEntry) => Promise<void>; onChange?: () => void;
};
/** No resource/I/O in construction or enqueue: one bounded async consumer per existing Pi session. */
export class UsageWriter {
  private queue: UsageEntry[] = [];
  private scheduled = false;
  private running = false;
  private dirty = true;
  private revision = 0;
  private timer?: NodeJS.Timeout;
  private stopped = false;
  private finalized = false;
  private closeFailures = 0;
  private readonly now: () => number;
  private readonly root: string;
  private readonly maximum: number;
  private state: RecorderState;
  constructor(identity: Identity, private options: UsageWriterOptions = {}) {
    this.now = options.now ?? Date.now; this.root = options.root ?? usageRoot();
    this.maximum = options.maximumQueue ?? 256;
    this.state = { version: 1, kind: "recorder", id: hash(identity.runtimeEpoch),
      session: hash(identity.localHostId + ":" + identity.nativeSessionId),
      startedAt: this.now(), updatedAt: this.now(), lastSuccessAt: null,
      accepted: 0, dropped: 0, pending: 0, writeFailures: 0, closed: false,
      reasons: ["auxiliary-usage-not-covered"] };
  }
  start() { this.schedule(); }
  enqueue(entry: UsageEntry): boolean {
    if (this.stopped || !validUsage(entry) || entry.occurredAt > this.now()) { this.mark("invalid-time"); return false; }
    if (this.queue.length >= this.maximum) { this.state.dropped++; this.mark("queue-full"); return false; }
    this.queue.push(entry); this.dirty = true; this.revision++; this.schedule(); return true;
  }
  mark(reason: string) {
    if (reasons.has(reason) && !this.state.reasons.includes(reason)) this.state.reasons.push(reason);
    this.dirty = true; this.revision++; this.schedule();
  }
  status() { return { version: 1, pending: this.queue.length, dropped: this.state.dropped,
    writeFailures: this.state.writeFailures, lastSuccessAt: this.state.lastSuccessAt,
    reasons: [...this.state.reasons] }; }
  close() {
    if (this.stopped) return;
    this.stopped = true; this.state.closed = true; this.dirty = true; this.revision++;
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    this.schedule();
  }
  private schedule() {
    if (this.finalized || this.running || this.scheduled || this.timer) return;
    this.scheduled = true;
    setImmediate(() => { this.scheduled = false; void this.flush(); }).unref();
  }
  private async write(entry: UsageEntry) {
    if (this.options.write) return this.options.write(entry);
    const dir = join(this.root, "spool", entry.id.slice(0, 2));
    await privateDirectory(dir);
    const path = join(dir, entry.id + ".json");
    const bytes = JSON.stringify(entry) + "\n";
    try {
      if (await readPrivate(path) !== bytes) throw Error("receipt-conflict");
      return;
    } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
    if ((await readdir(dir)).length >= (this.options.maximumShardFiles ?? 512)) throw Error("storage-capacity");
    await atomic(path, bytes, false);
  }
  async flush(): Promise<void> {
    if (this.finalized || this.running) return;
    const failuresBefore = this.state.writeFailures;
    this.running = true;
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    try {
      await privateDirectory(this.root); await privateDirectory(join(this.root, "recorders"));
      let count = 0;
      while (this.queue.length && count++ < 32) {
        try { await this.write(this.queue[0]); }
        catch (e) {
          const code = (e as Error).message;
          this.state.writeFailures++;
          this.mark(code === "receipt-conflict" || code === "storage-capacity" ? code : "write-failed");
          if (code === "receipt-conflict") { this.queue.shift(); this.state.dropped++; continue; }
          break;
        }
        this.queue.shift(); this.state.accepted++; this.state.lastSuccessAt = this.now(); this.dirty = true; this.revision++;
      }
      if (this.dirty) {
        this.state.updatedAt = this.now(); this.state.pending = this.queue.length;
        const revision = this.revision;
        await atomic(join(this.root, "recorders", this.state.id + ".json"), JSON.stringify(this.state) + "\n", true);
        if (revision === this.revision) this.dirty = false;
      }
    } catch { this.state.writeFailures++; if (!this.state.reasons.includes("write-failed")) this.state.reasons.push("write-failed"); this.dirty = true; }
    finally {
      this.running = false; this.options.onChange?.();
      if (this.stopped && this.state.writeFailures > failuresBefore && ++this.closeFailures >= 3) {
        // Preserve pending/failure facts, but do not retain a closed runtime
        // forever through a timer when storage cannot recover.
        this.finalized = true;
        if (!this.state.reasons.includes("close-flush-unconfirmed")) this.state.reasons.push("close-flush-unconfirmed");
        return;
      }
      if (this.stopped && this.queue.length === 0 && !this.dirty) { this.finalized = true; return; }
      if (this.queue.length || this.dirty) {
        if (this.stopped && this.state.writeFailures === failuresBefore) { this.schedule(); return; }
        this.timer = setTimeout(() => { this.timer = undefined; void this.flush(); }, 1000);
        this.timer.unref();
      }
    }
  }
}
