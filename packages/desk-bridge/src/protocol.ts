import { Buffer } from "node:buffer";

export const VERSION = 1;
export const MAX_FRAME = 65_536;
export const ACTIONS = [
	"session.message",
	"session.abort-current",
	"run.steer",
	"run.stop",
	"run.resume",
	"schedule.pause",
	"schedule.resume",
	"schedule.run",
	"schedule.delete",
] as const;
export type Action = (typeof ACTIONS)[number];
export type Identity = {
	localHostId: string;
	nativeSessionId: string;
	runtimeEpoch: string;
};
export type Tokens = {
	input: number | null;
	output: number | null;
	cacheRead: number | null;
	cacheWrite: number | null;
};
export type UsageReport = {
	source: string;
	scope: string;
	windowId: string;
	model?: string;
	observedAt?: number | null;
	startedAt: number | null;
	coverage: string;
	tokens: Tokens;
	cost: number | null;
	unresolvedChildren: number | null;
	includedRunIds: string[];
	accountingGroup?: string;
	reasons: string[];
};
export type Capabilities = {
	actions: Action[];
	queries: string[];
	owners: Record<string, string>;
};
export type Run = {
	key: string;
	runId?: string;
	parentRunId?: string;
	index?: number;
	owner: string;
	state: string;
	agent?: string;
	model?: string;
	effort?: string;
	terminalProof?: string;
	actions: Action[];
};
export type Schedule = {
	owner: string;
	scheduleId: string;
	name: string;
	state: string;
	actions: Action[];
};
export type InputNotice = {
	id: string;
	source: string;
	kind: string;
	startedAt: number;
};
export type Evidence = {
	id: string;
	source: string;
	category: string;
	status: string;
	head?: string;
	observedAt: number;
	nature: string;
};
export type Snapshot = {
	omitted?: Record<string, number>;
	identity: Identity;
	seq: number;
	observedAt: number;
	capabilities: Capabilities;
	display: {
		name: string;
		cwd?: string;
		branch?: string;
		worktree?: string;
		model?: string;
		effort?: string;
		mode: string;
		route?: { kind: string; sessionId: string; sessionFile?: string };
	};
	execution: string;
	pending: boolean | null;
	childCoverage: string;
	tools: string[];
	runs: Run[];
	schedules: Schedule[];
	usage: UsageReport[];
	inputs: InputNotice[];
	evidence: Evidence[];
	dropped: number;
	contextTokens: number | null;
};
export type Target = {
	owner: string;
	runId?: string;
	index?: number;
	scheduleId?: string;
};
export type Parameters = {
	text?: string;
	mode?: string;
	eventName?: string;
	eventId?: string;
};
export type Result = {
	status: "rejected" | "accepted" | "queued" | "requested" | "unknown";
	code: string;
	ownerRef?: string;
};
export type RecordV1 = {
	version: number;
	kind: string;
	identity: Identity;
	snapshot?: Snapshot;
	requestId?: string;
	issuedAt?: number;
	action?: Action;
	target?: Target;
	parameters?: Parameters;
	query?: string;
	result?: Result;
	operation?: {
		owner: string;
		runId: string;
		state: string;
		terminalProof?: string;
	};
};
export const object = (v: unknown): v is Record<string, unknown> =>
	v !== null && typeof v === "object" && !Array.isArray(v);
export const safeId = (v: unknown): v is string =>
	typeof v === "string" && /^[A-Za-z0-9._-]{1,128}$/.test(v);
export function text(v: unknown, limit = 512): string | undefined {
	if (typeof v !== "string") return undefined;
	const budget = Number.isSafeInteger(limit) ? Math.max(0, limit) : 512;
	let output = "",
		bytes = 0;
	for (const character of v) {
		const point = character.codePointAt(0)!;
		const scalar =
			point < 32 || point === 127 || (point >= 0xd800 && point <= 0xdfff)
				? " "
				: character;
		const size = Buffer.byteLength(scalar);
		if (bytes + size > budget) break;
		output += scalar;
		bytes += size;
	}
	return output;
}
export const identityValid = (v: unknown): v is Identity =>
	object(v) &&
	safeId(v.localHostId) &&
	safeId(v.nativeSessionId) &&
	safeId(v.runtimeEpoch);
export const sameIdentity = (a: Identity, b: Identity) =>
	a.localHostId === b.localHostId &&
	a.nativeSessionId === b.nativeSessionId &&
	a.runtimeEpoch === b.runtimeEpoch;
export function validate(v: unknown): asserts v is RecordV1 {
	if (!object(v) || v.version !== VERSION || !identityValid(v.identity))
		throw new Error("invalid-envelope");
	if (v.kind === "hello" || v.kind === "snapshot") {
		const s = v.snapshot;
		if (
			!object(s) ||
			!identityValid(s.identity) ||
			!sameIdentity(s.identity, v.identity) ||
			!Number.isSafeInteger(s.seq) ||
			Number(s.seq) < 0 ||
			!Number.isFinite(s.observedAt) ||
			!object(s.capabilities) ||
			!object(s.display)
		)
			throw new Error("invalid-snapshot");
		for (const [key, max] of [
			["tools", 32],
			["runs", 64],
			["schedules", 64],
			["usage", 8],
			["inputs", 32],
			["evidence", 32],
		] as const)
			if (!Array.isArray(s[key]) || s[key].length > max)
				throw new Error("invalid-snapshot");
	} else if (v.kind === "action") {
		if (
			!safeId(v.requestId) ||
			!Number.isFinite(v.issuedAt) ||
			!ACTIONS.includes(v.action as Action) ||
			!object(v.target) ||
			!["pi", "subagents", "schedule-prompt"].includes(
				String(v.target.owner),
			) ||
			(v.parameters !== undefined && !object(v.parameters))
		)
			throw new Error("invalid-action");
		if (
			object(v.parameters) &&
			v.parameters.text !== undefined &&
			(typeof v.parameters.text !== "string" ||
				Buffer.byteLength(v.parameters.text) > 16384)
		)
			throw new Error("invalid-text");
	} else if (v.kind === "query") {
		if (
			!safeId(v.requestId) ||
			![
				"refresh",
				"usage.refresh",
				"schedules.refresh",
				"operation.status",
			].includes(String(v.query))
		)
			throw new Error("invalid-query");
	} else if (v.kind === "action-result") {
		if (
			!safeId(v.requestId) ||
			!object(v.result) ||
			!["rejected", "accepted", "queued", "requested", "unknown"].includes(
				String(v.result.status),
			) ||
			!safeId(v.result.code)
		)
			throw new Error("invalid-result");
	} else if (v.kind === "operation-update") {
		if (!object(v.operation)) throw new Error("invalid-operation");
	} else throw new Error("unknown-kind");
}
export function encode(record: RecordV1): Buffer {
	validate(record);
	const raw = Buffer.from(JSON.stringify(record));
	if (raw.length > MAX_FRAME) throw new Error("oversized");
	return Buffer.concat([raw, Buffer.from("\n")]);
}
export class LineFramer {
	private carry = Buffer.alloc(0);
	get bufferedBytes() {
		return this.carry.length;
	}
	append(chunk: Buffer): RecordV1[] {
		const result: RecordV1[] = [];
		let start = 0;
		for (let i = 0; i < chunk.length; i++) {
			if (chunk[i] !== 10) continue;
			const length = this.carry.length + i - start;
			if (length === 0 || length > MAX_FRAME || result.length >= 128)
				throw new Error("invalid-frame");
			const data = Buffer.concat([this.carry, chunk.subarray(start, i)]);
			this.carry = Buffer.alloc(0);
			start = i + 1;
			const raw = new TextDecoder("utf-8", { fatal: true }).decode(data);
			const record: unknown = JSON.parse(raw);
			validate(record);
			result.push(record);
		}
		if (this.carry.length + chunk.length - start > MAX_FRAME)
			throw new Error("oversized");
		this.carry = Buffer.concat([this.carry, chunk.subarray(start)]);
		return result;
	}
}
