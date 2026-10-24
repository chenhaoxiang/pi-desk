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
export class OwnerRPC {
	private pending = new Set<() => void>();
	constructor(
		private events: ExtensionAPI["events"],
		readonly namespace: string,
		readonly timeoutMs = 2000,
	) {}
	call(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
		if (this.pending.size >= 4) return Promise.reject(new Error("owner-busy"));
		return new Promise((resolve, reject) => {
			const requestId = randomUUID();
			let done = false;
			let off = () => {};
			const finish = (error?: string, data?: unknown) => {
				if (done) return;
				done = true;
				clearTimeout(timer);
				off();
				this.pending.delete(cancel);
				error ? reject(new Error(error)) : resolve(data);
			};
			const cancel = () => finish("owner-unavailable");
			const timer = setTimeout(() => finish("owner-timeout"), this.timeoutMs);
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
					else finish("owner-rejected");
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
				finish("owner-unavailable");
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
export function subagentRuns(raw: unknown, cap: OwnerCapabilities): Run[] {
	if (!object(raw)) return [];
	const runs: Run[] = [];
	if (object(raw.asyncSnapshot) && Array.isArray(raw.asyncSnapshot.runs))
		for (const r of raw.asyncSnapshot.runs.slice(0, 64)) {
			if (!object(r) || !safeId(r.id)) continue;
			const state = text(r.state, 64) ?? "unknown";
			const actions: Action[] = [];
			if (["running", "queued"].includes(state)) {
				if (cap.stop) actions.push("run.stop");
				if (cap.steer && r.kind !== "workflow") actions.push("run.steer");
			}
			if (
				["paused", "stopped", "failed", "partial"].includes(state) &&
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
		const actions: Action[] = [];
		if (["running", "queued"].includes(state)) {
			if (cap.stop) actions.push("run.stop");
			if (cap.steer) actions.push("run.steer");
		}
		if (["stopped", "paused", "failed"].includes(state) && cap.resume)
			actions.push("run.resume");
		return [
			{
				key: "child-" + c.runId,
				runId: c.runId,
				parentRunId,
				owner: "subagents",
				state,
				agent: text(c.agent, 128),
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
		return { status: "rejected", code: "owner-rejected", ownerRef };
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
