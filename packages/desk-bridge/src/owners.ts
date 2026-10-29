import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	object,
	safeId,
	text,
	type Action,
	type Run,
	type Schedule,
	type Result,
} from "./protocol.ts";
const preAdmissionCodes = new Set([
	"invalid_request",
	"invalid_params",
	"unsupported_version",
	"unsupported_method",
	"no_active_session",
	"not_found",
	"invalid_state",
	"request-rejected",
]);
const ownerErrorCodes = new Set([
	...preAdmissionCodes,
	"execution_failed",
	"management-unavailable",
	"operation-outcome-unknown",
]);
export class OwnerFailure extends Error {
	constructor(
		readonly code: string,
		readonly notAdmitted = false,
	) {
		super(code);
		this.name = "OwnerFailure";
	}
}
function replyFailure(raw: unknown): OwnerFailure {
	const code =
		object(raw) && typeof raw.code === "string" && ownerErrorCodes.has(raw.code)
			? raw.code
			: "owner-error-unknown";
	return new OwnerFailure(code, preAdmissionCodes.has(code));
}
export function ownerFailureResult(error: unknown, ownerRef?: string): Result {
	return error instanceof OwnerFailure
		? {
				status: error.notAdmitted ? "rejected" : "unknown",
				code: error.code.startsWith("owner-")
					? error.code
					: "owner-" + error.code,
				ownerRef,
			}
		: { status: "unknown", code: "owner-outcome-unknown", ownerRef };
}
export class OwnerRPC {
	private pending = new Set<() => void>();
	constructor(
		private events: ExtensionAPI["events"],
		readonly namespace: string,
		readonly timeoutMs = 2000,
	) {}
	call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
		if (this.pending.size >= 4)
			return Promise.reject(new OwnerFailure("owner-busy", true));
		return new Promise((resolve, reject) => {
			const requestId = randomUUID();
			let done = false;
			let off = () => {};
			const finish = (error?: OwnerFailure, data?: unknown) => {
				if (done) return;
				done = true;
				clearTimeout(timer);
				off();
				this.pending.delete(cancel);
				error ? reject(error) : resolve(data);
			};
			const cancel = () => finish(new OwnerFailure("owner-unavailable"));
			const timer = setTimeout(
				() => finish(new OwnerFailure("owner-timeout")),
				this.timeoutMs,
			);
			timer.unref();
			this.pending.add(cancel);
			off = this.events.on(
				this.namespace + ":reply:" + requestId,
				(reply: unknown) => {
					if (
						!object(reply) ||
						reply.version !== 1 ||
						reply.requestId !== requestId
					)
						return;
					if (reply.success === true) finish(undefined, reply.data);
					else finish(replyFailure(reply.error));
				},
			);
			try {
				this.events.emit(this.namespace + ":request", {
					version: 1,
					requestId,
					method,
					params,
				});
			} catch {
				finish(new OwnerFailure("owner-unavailable"));
			}
		});
	}
	close() {
		for (const cancel of [...this.pending]) cancel();
	}
}
export type OwnerCapabilities = {
	status: boolean;
	cost: boolean;
	resume: boolean;
	steer: boolean;
	stop: boolean;
	schedules: string[];
	version: string;
};
export const absentOwner = (): OwnerCapabilities => ({
	status: false,
	cost: false,
	resume: false,
	steer: false,
	stop: false,
	schedules: [],
	version: "unavailable",
});
export function subagentCapabilities(raw: unknown): OwnerCapabilities {
	if (!object(raw) || !object(raw.capabilities)) return absentOwner();
	const c = raw.capabilities;
	return {
		status: object(c.fleetStatus) && c.fleetStatus.version === 1,
		cost: object(c.cost) && c.cost.version === 1,
		resume: c.resume === true,
		steer: c.nonRecoveringSteer === true,
		stop: c.stop === true,
		schedules: Array.isArray(c.managementActions)
			? c.managementActions.filter(
					(x): x is string =>
						typeof x === "string" &&
						/^schedule\.(list|show|history|pause|resume|run|delete)$/.test(x),
				)
			: [],
		version: text(raw.packageVersion ?? raw.version, 64) ?? "rpc-v1",
	};
}
function recoveryProjection(raw: unknown, fallbackRunId: unknown): Run["recovery"] {
	if (!object(raw) || !["waiting", "unknown", "ready", "blocked"].includes(String(raw.state)) || !["status", "reconcile", "resume", "inspect"].includes(String(raw.action))) return undefined;
	const reason = safeId(raw.reason) ? raw.reason : undefined;
	const runId = safeId(raw.runId) ? raw.runId : safeId(fallbackRunId) ? fallbackRunId : undefined;
	if (!reason || !safeId(runId)) return undefined;
	return {
		state: raw.state as NonNullable<Run["recovery"]>["state"],
		action: raw.action as NonNullable<Run["recovery"]>["action"],
		reason,
		runId,
		...(Number.isSafeInteger(raw.index) && Number(raw.index) >= 0 ? { index: Number(raw.index) } : {}),
	};
}
export function subagentRuns(raw: unknown, cap: OwnerCapabilities): Run[] {
	if (!object(raw)) return [];
	const runs: Run[] = [];
	if (object(raw.asyncSnapshot) && Array.isArray(raw.asyncSnapshot.runs))
		for (const r of raw.asyncSnapshot.runs.slice(0, 64)) {
			if (!object(r) || !safeId(r.id)) continue;
			const state = text(r.state, 64) ?? "unknown";
			const recovery = recoveryProjection(r.recovery, r.id);
			const actions: Action[] = [];
			if (["running", "queued"].includes(state)) {
				if (cap.stop) actions.push("run.stop");
				if (cap.steer && r.kind !== "workflow") actions.push("run.steer");
			}
			if (
				["paused", "complete", "failed", "partial"].includes(state) &&
				cap.resume
			)
				actions.push("run.resume");
			// Public snapshot does not claim native process terminal evidence.
			runs.push({
				key: "async-" + r.id,
				runId: r.id,
				owner: "subagents",
				state,
				agent: text(r.agent, 128),
				model: text(r.model, 128),
				effort: text(r.thinking, 64),
				...(recovery ? { recovery } : {}),
				actions,
			});
		}
	if (object(raw.fleet) && Array.isArray(raw.fleet.entries))
		for (const e of raw.fleet.entries.slice(0, 64 - runs.length)) {
			if (!object(e) || !safeId(e.key)) continue;
			// Fleet keys are display-only, never promoted to runId or used for control.
			runs.push({
				key: "fleet-" + e.key,
				owner: "subagents",
				state: "running",
				agent: text(e.agent, 128),
				model: text(e.model, 128),
				effort: text(e.effort, 64),
				actions: [],
			});
		}
	return runs;
}
export function subagentChildRuns(
	raw: unknown,
	cap: OwnerCapabilities,
	parentRunId: string,
): Run[] {
	if (
		!object(raw) ||
		!object(raw.details) ||
		!object(raw.details.workflowChildren) ||
		raw.details.workflowChildren.version !== 1 ||
		!Array.isArray(raw.details.workflowChildren.children)
	)
		return [];
	return raw.details.workflowChildren.children.slice(0, 32).flatMap((c) => {
		if (!object(c) || !safeId(c.runId)) return [];
		const state = text(c.state, 64) ?? "unknown";
		const recovery = recoveryProjection(c.recovery, c.runId);
		const actions: Action[] = [];
		if (["running", "queued"].includes(state)) {
			if (cap.stop) actions.push("run.stop");
			if (cap.steer) actions.push("run.steer");
		}
		if (
			["paused", "complete", "failed", "partial"].includes(state) &&
			cap.resume
		)
			actions.push("run.resume");
		return [
			{
				key: "child-" + c.runId,
				runId: c.runId,
				parentRunId,
				owner: "subagents",
				state,
				agent: text(c.agent, 128),
				...(recovery ? { recovery } : {}),
				actions,
			},
		];
	});
}
export function scheduleProjection(
	raw: unknown,
	owner: string,
	allowed: string[],
): Schedule[] {
	const list = Array.isArray(raw)
		? raw
		: object(raw) && Array.isArray(raw.jobs)
			? raw.jobs
			: object(raw) && Array.isArray(raw.schedules)
				? raw.schedules
				: object(raw) &&
						object(raw.details) &&
						object(raw.details.schedules) &&
						Array.isArray(raw.details.schedules.records)
					? raw.details.schedules.records
					: [];
	return list.slice(0, 64).flatMap((r) => {
		if (!object(r) || !safeId(r.id)) return [];
		const state =
			text(r.state ?? r.status, 64) ??
			(r.paused === true
				? "paused"
				: r.activeRunId
					? "running"
					: r.paused === false
						? "scheduled"
						: r.enabled === true
							? "enabled"
							: r.enabled === false
								? "paused"
								: "unknown");
		const actions = (
			[
				"schedule.pause",
				"schedule.resume",
				"schedule.run",
				"schedule.delete",
			] as Action[]
		).filter(
			(a) =>
				allowed.includes(a) &&
				(!Array.isArray(r.actions) || r.actions.includes(a)),
		);
		return [
			{ owner, scheduleId: r.id, name: text(r.name) ?? r.id, state, actions },
		];
	});
}
export function ownerResult(
	raw: unknown,
	fallback: string,
	ownerRef?: string,
): Result {
	if (!object(raw))
		return { status: "unknown", code: "owner-response-unknown", ownerRef };
	if (raw.success === false || raw.isError === true)
		return ownerFailureResult(replyFailure(raw.error), ownerRef);
	const details = object(raw.details) ? raw.details : raw;
	if (safeId(details.asyncId)) ownerRef = details.asyncId;
	else if (safeId(details.runId)) ownerRef = details.runId;
	if (details.deliveryStatus === "queued" || details.status === "queued")
		return { status: "queued", code: "owner-queued", ownerRef };
	if (details.deliveryStatus === "delivered")
		return { status: "accepted", code: "owner-delivered", ownerRef };
	if (details.state === "stopping")
		return { status: "accepted", code: "stop-requested", ownerRef };
	return { status: "accepted", code: fallback, ownerRef };
}
