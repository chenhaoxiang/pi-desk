import type {
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
	sameIdentity,
	safeId,
	type Identity,
	type RecordV1,
	type Result,
	type Snapshot,
} from "./protocol.ts";
import { OwnerRPC, ownerResult, ownerFailureResult } from "./owners.ts";
export class ActionRouter {
	private cache = new Map<
		string,
		{ fingerprint: string; expires: number; promise: Promise<Result> }
	>();
	private active = 0;
	private live = true;
	constructor(
		private pi: Pick<ExtensionAPI, "sendUserMessage">,
		private context: () => ExtensionContext | undefined,
		private current: () => Snapshot,
		private subagents: OwnerRPC,
		private schedules: OwnerRPC,
		private now = Date.now,
	) {}
	close() {
		this.live = false;
	}
	async handle(record: RecordV1): Promise<Result> {
		const s = this.current();
		if (!this.live || !sameIdentity(record.identity, s.identity))
			return { status: "rejected", code: "stale-epoch" };
		if (!record.requestId || !record.action || !record.target)
			return { status: "rejected", code: "invalid-action" };
		const now = this.now();
		const fingerprint = JSON.stringify([
			record.action,
			record.target.owner,
			record.target.runId,
			record.target.index,
			record.target.scheduleId,
			record.parameters?.text,
			record.parameters?.mode,
			record.parameters?.eventName,
			record.parameters?.eventId,
		]);
		for (const [id, item] of this.cache)
			if (item.expires < now) this.cache.delete(id);
		const previous = this.cache.get(record.requestId);
		if (previous)
			return previous.fingerprint === fingerprint
				? previous.promise
				: { status: "rejected", code: "request-id-conflict" };
		if (
			!record.issuedAt ||
			now - record.issuedAt > 30000 ||
			record.issuedAt > now + 5000
		)
			return { status: "unknown", code: "request-window-expired" };
		if (this.cache.size >= 128 || this.active >= 4)
			return { status: "rejected", code: "action-capacity" };
		let resolve!: (r: Result) => void;
		const promise = new Promise<Result>((r) => {
			resolve = r;
		});
		this.cache.set(record.requestId, {
			fingerprint,
			expires: now + 600000,
			promise,
		});
		this.active++;
		// Admission and de-dup occur before dispatch; all execution is off the observation handler.
		setImmediate(() => {
			void this.dispatch(record)
				.then(resolve, (error: unknown) =>
					resolve(
						ownerFailureResult(
							error,
							record.target?.runId ?? record.target?.scheduleId,
						),
					),
				)
				.finally(() => this.active--);
		}).unref();
		return promise;
	}
	private async dispatch(r: RecordV1): Promise<Result> {
		const s = this.current();
		const ctx = this.context();
		if (!this.live || !ctx || !sameIdentity(s.identity, r.identity))
			return { status: "rejected", code: "stale-context" };
		const action = r.action!;
		const target = r.target!;
		const p = r.parameters ?? {};
		if (!s.capabilities.actions.includes(action))
			return { status: "rejected", code: "unsupported-action" };
		if (action === "session.message") {
			if (
				target.owner !== "pi" ||
				target.runId ||
				target.scheduleId ||
				!p.text?.trim() ||
				Buffer.byteLength(p.text) > 16384 ||
				p.text.includes("\0") ||
				p.text.trimStart().startsWith("/") ||
				!["steer", "followUp"].includes(p.mode ?? "")
			)
				return { status: "rejected", code: "invalid-message" };
			this.pi.sendUserMessage(p.text, {
				deliverAs: p.mode as "steer" | "followUp",
			});
			return { status: "requested", code: "native-send-called" };
		}
		if (action === "session.abort-current") {
			if (target.owner !== "pi" || target.runId || target.scheduleId)
				return { status: "rejected", code: "invalid-target" };
			ctx.abort();
			return { status: "requested", code: "abort-current-requested" };
		}
		if (action.startsWith("run.")) {
			if (
				target.owner !== "subagents" ||
				!safeId(target.runId) ||
				target.scheduleId ||
				target.index !== undefined
			)
				return { status: "rejected", code: "invalid-run-target" };
			const run = s.runs.find(
				(v) => v.runId === target.runId && v.owner === target.owner,
			);
			if (!run?.actions.includes(action))
				return { status: "rejected", code: "run-action-unavailable" };
			const params: Record<string, unknown> = { id: target.runId };
			if (action !== "run.stop") {
				if (
					!p.text?.trim() ||
					Buffer.byteLength(p.text) > 16384 ||
					p.text.includes("\0")
				)
					return { status: "rejected", code: "invalid-message" };
				params.message = p.text;
				if (action === "run.steer") {
					if (!["steer", "follow_up"].includes(p.mode ?? ""))
						return { status: "rejected", code: "invalid-mode" };
					params.mode = p.mode;
				}
			}
			const reply = await this.subagents.call(action.slice(4), params);
			return ownerResult(
				reply,
				action === "run.stop" ? "stop-requested" : "owner-accepted",
				target.runId,
			);
		}
		if (action.startsWith("schedule.")) {
			if (
				!["subagents", "schedule-prompt"].includes(target.owner) ||
				!safeId(target.scheduleId) ||
				target.runId
			)
				return { status: "rejected", code: "invalid-schedule-target" };
			const schedule = s.schedules.find(
				(v) => v.scheduleId === target.scheduleId && v.owner === target.owner,
			);
			if (!schedule?.actions.includes(action))
				return { status: "rejected", code: "schedule-action-unavailable" };
			const reply =
				target.owner === "subagents"
					? await this.subagents.call("manage", {
							action,
							id: target.scheduleId,
						})
					: await this.schedules.call(action, { id: target.scheduleId });
			return ownerResult(
				reply,
				action === "schedule.pause"
					? "future-triggers-paused"
					: "owner-accepted",
				target.scheduleId,
			);
		}
		return { status: "rejected", code: "unsupported-action" };
	}
}
