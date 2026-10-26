import { randomUUID, createHash } from "node:crypto";
import { hostname } from "node:os";
import type {
	ExtensionAPI,
	ExtensionContext,
	TurnEndEvent,
} from "@earendil-works/pi-coding-agent";
import {
	object,
	safeId,
	sameIdentity,
	text,
	type Snapshot,
	type RecordV1,
	type Evidence,
	type InputNotice,
	type Action,
} from "./protocol.ts";
import { AttachmentUsage, costProjection } from "./usage.ts";
import { UsageWriter, usageEntry } from "./usage-store.ts";
import {
	OwnerRPC,
	absentOwner,
	subagentCapabilities,
	subagentRuns,
	subagentChildRuns,
	scheduleProjection,
} from "./owners.ts";
import { ActionRouter } from "./actions.ts";
import { BridgeTransport } from "./transport.ts";
import { runtimePath, helperPath } from "./security.ts";
import { projectMetadata } from "./metadata.ts";
import { displayBudget } from "./budget.ts";
import { captureTerminalRoute } from "./terminal-route.ts";
import { MAX_CREATED_AT_MS } from "./protocol.ts";
export type TransportLike = Pick<
	BridgeTransport,
	"start" | "publish" | "reply" | "close" | "dropped"
>;
export function sessionCreatedAt(timestamp: unknown): { createdAt: number | null; source: "session-header" | "unknown" } {
	const value = typeof timestamp === "string" ? Date.parse(timestamp) : NaN;
	return Number.isSafeInteger(value) && value >= 0 && value <= MAX_CREATED_AT_MS ? { createdAt: value, source: "session-header" } : { createdAt: null, source: "unknown" };
}
export type SessionOptions = {
	transport?: (
		hello: () => RecordV1,
		receive: (record: RecordV1) => void,
	) => TransportLike;
	now?: () => number;
	sourceRevision?: string;
	usageRoot?: string | false;
};
export class DeskSession {
	private ctx?: ExtensionContext;
	private stopped = false;
	private scheduled = false;
	private refreshing = false;
	private refreshAgain = false;
	private refreshScheduled = false;
	private refreshCost = false;
	private refreshExplicit = false;
	private refreshRunId?: string;
	private refreshScope = "refresh";
	private ownerRefreshTimes = new Map<string, number>();
	private receiving = 0;
	private off: (() => void)[] = [];
	private cap = absentOwner();
	private scheduleActions: string[] = [];
	private subagents: OwnerRPC;
	private schedules: OwnerRPC;
	private router: ActionRouter;
	private transport: TransportLike;
	private usage: AttachmentUsage;
	private usageWriter?: UsageWriter;
	private nativePrompts = new Map<string, { count: number; id: string }>();
	private tools = new Map<string, string>();
	private inputs = new Map<string, InputNotice>();
	private sequence = 0;
	private snapshot: Snapshot;
	private now: () => number;
	private finalError = false;
	private settledObserved = false;
	private observationDrops = 0;
	private metadataLoaded = false;
	private bridgeSource: string;
	private terminalRoute?: NonNullable<Snapshot["display"]["route"]>;
	constructor(
		private pi: ExtensionAPI,
		ctx: ExtensionContext,
		options: SessionOptions = {},
	) {
		this.ctx = ctx;
		this.now = options.now ?? Date.now;
		this.bridgeSource =
			options.sourceRevision && /^[a-f0-9]{40}$/.test(options.sourceRevision)
				? options.sourceRevision
				: "development";
		const identity = {
			localHostId: createHash("sha256")
				.update(hostname() + ":" + String(process.getuid?.()))
				.digest("hex")
				.slice(0, 32),
			nativeSessionId: ctx.sessionManager.getSessionId(),
			runtimeEpoch: randomUUID(),
		};
		if (!safeId(identity.nativeSessionId)) throw Error("invalid-session-id");
		this.usage = new AttachmentUsage(identity.runtimeEpoch, this.now());
		const header = typeof ctx.sessionManager.getHeader === "function" ? ctx.sessionManager.getHeader() : null;
		const created = sessionCreatedAt(header?.timestamp);
		this.snapshot = {
			identity,
			seq: 0,
			observedAt: this.now(),
			capabilities: {
				actions: ["session.message", "session.abort-current"],
				queries: [
					"refresh",
					"usage.refresh",
					"schedules.refresh",
					"operation.status",
				],
				owners: {
					pi: "extension-api-1.4",
					"pi-desk-bridge": this.bridgeSource,
				},
			},
			display: {
				name: "Pi", mode: ctx.mode,
				createdAt: created.createdAt, createdAtSource: created.source,
			},
			execution: ctx.isIdle() ? "unknown" : "running",
			pending: null,
			childCoverage: "unknown",
			tools: [],
			runs: [],
			schedules: [],
			usage: [],
			inputs: [],
			evidence: [],
			dropped: 0,
			contextTokens: null,
		};
		if (options.usageRoot !== false) {
			this.usageWriter = new UsageWriter(identity, { root: options.usageRoot, now: this.now, onChange: () => this.changed() });
			this.usageWriter.start();
		}
		this.subagents = new OwnerRPC(pi.events, "subagents:rpc:v1");
		this.schedules = new OwnerRPC(pi.events, "schedule:rpc:v1");
		this.router = new ActionRouter(
			pi,
			() => this.ctx,
			() => this.snapshot,
			this.subagents,
			this.schedules,
			this.now,
		);
		this.transport =
			options.transport?.(
				() => this.record("hello"),
				(r) => this.receive(r),
			) ??
			new BridgeTransport(
				runtimePath(),
				helperPath(),
				() => this.record("hello"),
				(r) => this.receive(r),
			);
		this.off.push(
			pi.events.on("subagents:rpc:v1:ready", () => this.deferRefresh(false)),
		);
		this.off.push(
			pi.events.on("schedule:rpc:v1:ready", () => this.deferRefresh(false)),
		);
		this.off.push(
			pi.events.on("subagent:async-complete", () => this.deferRefresh(false)),
		);
		this.off.push(
			pi.events.on("subagent:foreground-complete", () =>
				this.deferRefresh(false),
			),
		);
		this.off.push(
			pi.events.on("subagent:async-started", () => this.deferRefresh(false)),
		);
		this.off.push(
			pi.events.on("subagent:child-status", (raw) => {
				if (object(raw) && raw.version === 1 && safeId(raw.childRunId) && safeId(raw.runId) && ["started", "stopping", "stopped"].includes(String(raw.status))) {
					const runId = raw.childRunId;
					const state = raw.status === "started" ? "running" : String(raw.status);
					const existing = this.snapshot.runs.find(r => r.runId === runId);
					this.snapshot.runs = [...this.snapshot.runs.filter(r => r.runId !== runId), {
						key: existing?.key ?? "event-" + runId, runId, parentRunId: raw.runId,
						owner: "subagents", state, agent: text(raw.agent, 128), actions: [],
					}].slice(-64);
					this.snapshot.childCoverage = "partial";
					this.changed();
				}
			}),
		);
		this.off.push(
			pi.events.on("subagent:process-terminal", (r) => {
				if (
					object(r) &&
					r.version === 1 &&
					r.childIndex === undefined &&
					safeId(r.runId) &&
					this.snapshot.runs.some((run) => run.runId === r.runId)
				) {
					if (r.state === "observed") {
						this.snapshot.runs = this.snapshot.runs.map((run) =>
							run.runId === r.runId
								? { ...run, terminalProof: "observed" }
								: run,
						);
						this.transport.reply({
							version: 1,
							kind: "operation-update",
							identity: this.snapshot.identity,
							operation: {
								owner: "subagents",
								runId: r.runId,
								state: "terminal",
								terminalProof: "observed",
							},
						});
						this.changed();
					}
					this.deferRefresh(false);
				}
			}),
		);
		this.off.push(
			pi.events.on("pi:input-required", (r) => {
				try {
					this.question(r);
				} catch {}
			}),
		);
		// Optional safe summary seam. This does not claim a real Gate/CI producer exists.
		this.off.push(pi.events.on("pi-desk:evidence:v1", (r) => this.evidence(r)));
		const sessionFile = typeof ctx.sessionManager.getSessionFile === "function" ? ctx.sessionManager.getSessionFile() : undefined;
		void captureTerminalRoute(identity.nativeSessionId, sessionFile, ctx.cwd).then((route) => {
			if (this.stopped) return;
			if (route.kind !== "unavailable") this.terminalRoute = route;
			this.changed();
		});
		try {
			this.observe(ctx);
			this.transport.start();
		} catch {
			this.observationDrops++;
		}
		this.deferRefresh(false);
	}
	private record(kind: string): RecordV1 {
		this.snapshot.capabilities.actions = [
			...new Set<Action>([
				"session.message",
				"session.abort-current",
				...this.snapshot.runs.flatMap((r) => r.actions),
				...this.snapshot.schedules.flatMap((s) => s.actions),
			]),
		];
		this.snapshot.seq = ++this.sequence;
		this.snapshot.observedAt = this.now();
		this.snapshot.dropped =
			(this.transport?.dropped ?? 0) + this.observationDrops;
		return {
			version: 1,
			kind,
			identity: this.snapshot.identity,
			snapshot: displayBudget({
				...this.snapshot,
				usageRecorder: this.usageWriter?.status(),
				usage: [
					...this.usage.reports(),
					...this.snapshot.usage.filter((u) => u.source !== "pi.turn_end"),
				],
			}),
		};
	}
	private changed() {
		if (this.stopped || this.scheduled) return;
		this.scheduled = true;
		setImmediate(() => {
			this.scheduled = false;
			if (!this.stopped) {
				try {
					this.transport.publish(this.record("snapshot"));
				} catch {
					this.observationDrops++;
				}
			}
		}).unref();
	}
	observe(ctx: ExtensionContext) {
		if (this.stopped) return;
		this.ctx = ctx;
		this.snapshot.display = {
			...this.snapshot.display,
			name: this.snapshot.display.name,
			cwd: text(ctx.cwd),
			branch: this.snapshot.display.branch,
			worktree: this.snapshot.display.worktree,
			model: ctx.model
				? text(ctx.model.provider + "/" + ctx.model.id, 128)
				: undefined,
			effort: text(ctx.thinkingLevel ?? this.pi.getThinkingLevel(), 64),
			mode: ctx.mode,
		};
		if (this.terminalRoute) this.snapshot.display.route = this.terminalRoute;
		this.snapshot.pending = ctx.hasPendingMessages();
		this.changed();
	}
	observationFault() {
		this.observationDrops++;
		this.usage.markPartial("observation-fault");
		this.usageWriter?.mark("observation-fault");
		this.changed();
	}
	lifecycle(kind: string, ctx: ExtensionContext, aborted = false) {
		this.observe(ctx);
		if (kind === "agent_start") {
			this.finalError = false;
			this.settledObserved = false;
			this.snapshot.execution = "running";
		}
		// agent_end is deliberately not a completion boundary.
		if (kind === "agent_settled") {
			this.settledObserved = true;
			this.snapshot.execution = aborted
				? "aborted"
				: this.finalError
					? "failed"
					: this.snapshot.pending
						? "running"
						: this.snapshot.runs.some((r) =>
									["running", "queued"].includes(r.state),
								)
							? "waiting-children"
							: "settled";
			// No automatic owner cost/status/artifact read at a Pi turn boundary.
		}
		this.changed();
	}
	tool(start: boolean, id: string, name: string, ctx: ExtensionContext) {
		this.observe(ctx);
		if (start) {
			if (this.tools.size < 32 && id.length <= 256 && safeId(name))
				this.tools.set(id, name);
		} else this.tools.delete(id);
		this.snapshot.tools = [...new Set(this.tools.values())];
		this.changed();
	}
	turn(event: TurnEndEvent, ctx: ExtensionContext) {
		this.observe(ctx);
		if (event.message.role === "assistant") {
			const entry = usageEntry(this.snapshot.identity, event.messageEntryId, event.message, this.now());
			if (entry) {
				this.usageWriter?.enqueue(entry);
				if (Object.values(entry.tokens).some(v => v === null)) this.usageWriter?.mark("missing-usage");
			} else this.usageWriter?.mark(safeId(event.messageEntryId) ? "invalid-time" : "missing-receipt");
			this.usage.settle(
				event.messageEntryId,
				event.message.usage,
				text(event.message.provider + "/" + event.message.model, 128) ??
					"unknown",
			);
			this.finalError = event.message.stopReason === "error";
		}
		const results = event.toolResults.slice(0, 256);
		for (let i = 0; i < results.length; i++) {
			const r = results[i];
			if (r.usage) this.usageWriter?.mark("tool-usage-unattributed");
			if (r.usage)
				this.usage.settle(
					event.toolResultEntryIds[i],
					r.usage,
					"tool-usage-model-unknown",
				);
		}
		if (
			event.entries
				.slice(0, 64)
				.some((e) => e.type === "compaction" || e.type === "context_edit")
		)
		{ this.usage.markPartial("boundary-usage-not-covered"); this.usageWriter?.mark("boundary-usage-not-covered"); }
		this.changed();
	}
	prompt(start: boolean, kind: string) {
		if (!["select", "confirm", "input", "editor"].includes(kind)) return;
		const current = this.nativePrompts.get(kind);
		if (start) {
			if (current) {
				current.count = Math.min(32, current.count + 1);
			} else if (this.inputs.size < 32) {
				const id = "native-" + randomUUID();
				this.nativePrompts.set(kind, { count: 1, id });
				this.inputs.set(id, {
					id,
					source: "pi.ui_prompt",
					kind,
					startedAt: this.now(),
				});
			}
		} else if (current) {
			current.count--;
			if (current.count <= 0) {
				this.inputs.delete(current.id);
				this.nativePrompts.delete(kind);
			}
		}
		this.snapshot.inputs = [...this.inputs.values()];
		this.changed();
	}
	private question(raw: unknown) {
		if (
			!object(raw) ||
			raw.version !== 1 ||
			raw.source !== "ask_user_question" ||
			!safeId(raw.id)
		)
			return;
		// This public producer is process-local on the current session event bus.
		const id = "question-" + raw.id;
		if (raw.phase === "start" && this.inputs.size < 32)
			this.inputs.set(id, {
				id,
				source: "pi:input-required",
				kind: "question",
				startedAt: this.now(),
			});
		if (raw.phase === "end") this.inputs.delete(id);
		this.snapshot.inputs = [...this.inputs.values()];
		this.changed();
	}
	private evidence(raw: unknown) {
		if (
			!object(raw) ||
			raw.version !== 1 ||
			raw.sessionId !== this.snapshot.identity.nativeSessionId ||
			!safeId(raw.id) ||
			!safeId(raw.source) ||
			!["gate", "ci", "merge", "post-ci"].includes(String(raw.category)) ||
			!["fact", "advice", "unknown"].includes(String(raw.nature))
		)
			return;
		const e: Evidence = {
			id: raw.id,
			source: raw.source,
			category: String(raw.category),
			status: ["pending", "passed", "failed", "unknown"].includes(
				String(raw.status),
			)
				? String(raw.status)
				: "unknown",
			nature: String(raw.nature),
			observedAt: this.now(),
		};
		if (typeof raw.head === "string" && /^[a-f0-9]{7,64}$/.test(raw.head))
			e.head = raw.head;
		this.snapshot.evidence = [
			...this.snapshot.evidence.filter((x) => x.id !== e.id).slice(-31),
			e,
		];
		this.changed();
	}
	private deferRefresh(cost: boolean, explicit = false, runId?: string, scope = "refresh") {
		if (this.stopped) return;
		this.refreshCost ||= cost && explicit;
		this.refreshExplicit ||= explicit;
		if (explicit) { this.refreshScope = scope; this.refreshRunId = safeId(runId) ? runId : undefined; }
		if (this.refreshing) { this.refreshAgain = true; return; }
		if (this.refreshScheduled) return;
		this.refreshScheduled = true;
		setImmediate(() => {
			this.refreshScheduled = false;
			const includeCost = this.refreshCost, explicit = this.refreshExplicit, runId = this.refreshRunId, scope = this.refreshScope;
			this.refreshCost = false; this.refreshExplicit = false; this.refreshRunId = undefined; this.refreshScope = "refresh";
			void this.refresh(includeCost, explicit, runId, scope).catch(() => {
				this.observationDrops++;
			});
		}).unref();
	}
	async refresh(cost: boolean, explicit = false, runId?: string, scope = "refresh") {
		if (this.stopped) return;
		try {
			this.snapshot.display.name = text(this.pi.getSessionName()) ?? "Pi";
		} catch {}
		if (!this.metadataLoaded && this.ctx) {
			this.metadataLoaded = true;
			void projectMetadata(this.ctx.cwd).then((result) => {
				if (this.stopped) return;
				this.snapshot.display = {
					...this.snapshot.display,
					branch: text(result.branch),
					worktree: text(result.worktree),
				};
				this.changed();
			});
		}
		// Owner RPC dispatch can perform synchronous artifact work on this same
		// event loop. Only an explicit current-session UI query may enter it.
		if (!explicit) { this.changed(); return; }
		const queryKey = scope + ":" + (runId ?? "session");
		if (this.now() - (this.ownerRefreshTimes.get(queryKey) ?? Number.NEGATIVE_INFINITY) < (cost ? 5000 : 1500)) return;
		try {
			const usage = this.ctx?.getContextUsage();
			this.snapshot.contextTokens =
				usage &&
				typeof usage.tokens === "number" &&
				Number.isFinite(usage.tokens)
					? usage.tokens
					: null;
		} catch {
			this.snapshot.contextTokens = null;
		}

		if (this.refreshing) {
			this.refreshAgain ||= cost;
			return;
		}
		this.refreshing = true;
		if (this.ownerRefreshTimes.size >= 16 && !this.ownerRefreshTimes.has(queryKey)) this.ownerRefreshTimes.delete(this.ownerRefreshTimes.keys().next().value!);
		this.ownerRefreshTimes.set(queryKey, this.now());
		try {
			if (!this.cap.status) {
				try {
					this.cap = subagentCapabilities(await this.subagents.call("ping"));
				} catch {
					this.cap = absentOwner();
				}
			}
			if (this.cap.status) {
				try {
					const raw = await this.subagents.call("status");
					if (this.stopped) return;
					let runs = subagentRuns(raw, this.cap);
					const roots =
						object(raw) &&
						object(raw.asyncSnapshot) &&
						Array.isArray(raw.asyncSnapshot.runs)
							? raw.asyncSnapshot.runs
									.filter(
										(r) => object(r) && r.kind === "workflow" && safeId(r.id),
									)
									.slice(-4)
							: [];
					for (const root of roots.filter(r => runId !== undefined && object(r) && r.id === runId)) {
						if (!object(root) || !safeId(root.id)) continue;
						try {
							const detail = await this.subagents.call("status", {
								id: root.id,
							});
							const children = subagentChildRuns(detail, this.cap, root.id);
							const seen = new Set(
								runs.flatMap((r) => (r.runId ? [r.runId] : [])),
							);
							runs = [
								...runs,
								...children.filter((c) => !seen.has(c.runId!)),
							].slice(0, 64);
							if (
								object(detail) &&
								object(detail.details) &&
								object(detail.details.workflowTerminalProof)
							) {
								const proof = detail.details.workflowTerminalProof;
								if (
									proof.version === 1 &&
									proof.runId === root.id &&
									proof.state === "observed" &&
									proof.dispatchClosed === true
								) {
									runs = runs.map((r) =>
										r.runId === root.id
											? { ...r, terminalProof: "observed" }
											: r,
									);
									this.transport.reply({
										version: 1,
										kind: "operation-update",
										identity: this.snapshot.identity,
										operation: {
											owner: "subagents",
											runId: root.id,
											state: "terminal",
											terminalProof: "observed",
										},
									});
								}
							}
						} catch {}
					}
					this.snapshot.runs = runs;
					this.changed();
					this.snapshot.childCoverage =
						object(raw) &&
						object(raw.asyncSnapshot) &&
						object(raw.asyncSnapshot.omitted) &&
						Number(raw.asyncSnapshot.omitted.runs) === 0 &&
						Number(raw.asyncSnapshot.omitted.children) === 0 &&
						raw.asyncSnapshot.omitted.byteLimitExceeded !== true &&
						object(raw.fleet) &&
						raw.fleet.omitted === 0 &&
						roots.length < 4 &&
						runs.length < 64
							? "owner-reported"
							: "partial";
				} catch {
					this.snapshot.childCoverage = "unknown";
					this.cap = absentOwner();
					this.snapshot.runs = this.snapshot.runs.map((r) => ({
						...r,
						state: "unknown",
						actions: [],
					}));
				}
				if (cost && this.cap.cost) {
					try {
						const raw = await this.subagents.call("cost");
						const report = costProjection(
							raw,
							this.snapshot.identity.nativeSessionId,
							null,
						);
						if (report) this.snapshot.usage = [report];
					} catch {
						this.snapshot.usage = this.snapshot.usage.map((u) => ({
							...u,
							coverage: "partial",
							reasons: ["owner-unavailable"],
						}));
					}
				}
				if (this.cap.schedules.includes("schedule.list")) {
					try {
						const raw = await this.subagents.call("manage", {
							action: "schedule.list",
						});
						this.snapshot.schedules = [
							...this.snapshot.schedules.filter((s) => s.owner !== "subagents"),
							...scheduleProjection(raw, "subagents", this.cap.schedules),
						].slice(0, 64);
					} catch {
						this.snapshot.schedules = this.snapshot.schedules.map((s) =>
							s.owner === "subagents"
								? { ...s, state: "unknown", actions: [] }
								: s,
						);
					}
				}
			}
			if (!this.scheduleActions.length) {
				try {
					const raw = await this.schedules.call("ping");
					if (
						object(raw) &&
						object(raw.capabilities) &&
						Array.isArray(raw.capabilities.managementActions)
					)
						this.scheduleActions = raw.capabilities.managementActions.filter(
							(x): x is string =>
								typeof x === "string" &&
								/^schedule\.(list|pause|resume|delete|run)$/.test(x),
						);
				} catch {}
			}
			if (this.scheduleActions.includes("schedule.list")) {
				try {
					const raw = await this.schedules.call("schedule.list");
					this.snapshot.schedules = [
						...this.snapshot.schedules.filter(
							(s) => s.owner !== "schedule-prompt",
						),
						...scheduleProjection(raw, "schedule-prompt", this.scheduleActions),
					].slice(0, 64);
				} catch {
					this.scheduleActions = [];
					this.snapshot.schedules = this.snapshot.schedules.map((s) =>
						s.owner === "schedule-prompt"
							? { ...s, state: "unknown", actions: [] }
							: s,
					);
				}
			}
			const actions: Action[] = ["session.message", "session.abort-current"];
			for (const r of this.snapshot.runs)
				for (const a of r.actions) if (!actions.includes(a)) actions.push(a);
			for (const s of this.snapshot.schedules)
				for (const a of s.actions) if (!actions.includes(a)) actions.push(a);
			this.snapshot.capabilities = {
				actions,
				queries: this.snapshot.capabilities.queries,
				owners: {
					pi: "extension-api-1.4",
					"pi-desk-bridge": this.bridgeSource,
					"pi-desk-usage": this.usageWriter ? "spool-v1" : "unavailable",
					subagents: this.cap.version,
					"schedule-prompt": this.scheduleActions.length
						? "rpc-v1"
						: "unavailable",
				},
			};
			if (
				this.settledObserved &&
				!this.finalError &&
				this.snapshot.execution !== "aborted" &&
				this.ctx?.isIdle()
			) {
				this.snapshot.pending = this.ctx.hasPendingMessages();
				this.snapshot.execution = this.snapshot.pending
					? "running"
					: this.snapshot.runs.some((r) =>
								["running", "queued"].includes(r.state),
							)
						? "waiting-children"
						: "settled";
			}
			this.changed();
		} finally {
			this.refreshing = false;
			if (this.refreshAgain) {
				this.refreshAgain = false;
				this.deferRefresh(false);
			}
		}
	}
	private receive(r: RecordV1) {
		if (this.stopped) return;
		if (r.kind === "action") {
			if (this.receiving >= 8) {
				this.transport.reply({
					version: 1,
					kind: "action-result",
					identity: this.snapshot.identity,
					requestId: r.requestId,
					result: { status: "rejected", code: "action-capacity" },
				});
				return;
			}
			this.receiving++;
			void this.router
				.handle(r)
				.then((result) => {
					if (this.stopped) return;
					this.transport.reply({
						version: 1,
						kind: "action-result",
						identity: this.snapshot.identity,
						requestId: r.requestId,
						result,
					});
					this.deferRefresh(false);
				})
				.finally(() => this.receiving--);
		}
		if (
			r.kind === "query" &&
			sameIdentity(r.identity, this.snapshot.identity)
		) {
			this.changed();
			this.deferRefresh(r.query === "usage.refresh", true, r.target?.owner === "subagents" ? r.target.runId : undefined, r.query);
		}
	}
	close() {
		if (this.stopped) return;
		this.stopped = true;
		this.usageWriter?.close();
		this.ctx = undefined;
		for (const off of this.off) off();
		this.off = [];
		this.router.close();
		this.subagents.close();
		this.schedules.close();
		this.transport.close();
		this.inputs.clear();
		this.nativePrompts.clear();
		this.tools.clear();
	}
}
