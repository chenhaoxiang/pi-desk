import type { Tokens, UsageReport } from "./protocol.ts";
import { object, safeId } from "./protocol.ts";
export const emptyTokens = (): Tokens => ({
	input: null,
	output: null,
	cacheRead: null,
	cacheWrite: null,
});
export function tokens(value: unknown): Tokens {
	const result = emptyTokens();
	if (!object(value)) return result;
	for (const k of Object.keys(result) as (keyof Tokens)[]) {
		const n = value[k];
		if (
			typeof n === "number" &&
			Number.isFinite(n) &&
			n >= 0 &&
			Number.isSafeInteger(n)
		)
			result[k] = n;
	}
	return result;
}
export class AttachmentUsage {
	private seen = new Set<string>();
	private totals: Tokens = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
	private reasons = new Set(["attachment-only", "auxiliary-usage-not-covered"]);
	private consumed = false;
	private models = new Map<string, Tokens>();
	private observed = new Map<string, number>();
	private observedAt: number | null = null;
	constructor(
		readonly windowId: string,
		readonly startedAt = Date.now(),
		readonly maximumReceipts = 4096,
	) {}
	settle(receipt: unknown, usage: unknown, model = "unknown"): void {
		if (!safeId(receipt)) {
			this.reasons.add("missing-receipt");
			return;
		}
		if (this.seen.has(receipt)) return;
		if (this.seen.size >= this.maximumReceipts) {
			this.reasons.add("receipt-window-full");
			return;
		}
		this.seen.add(receipt);
		this.consumed = true;
		const t = tokens(usage);
		const group =
			this.models.has(model) || this.models.size < 5 ? model : "other-models";
		if (group === "other-models") this.reasons.add("model-window-full");
		const subtotal = this.models.get(group) ?? {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
		};
		for (const key of Object.keys(t) as (keyof Tokens)[]) {
			const n = (subtotal[key] ?? 0) + (t[key] ?? 0);
			subtotal[key] =
				subtotal[key] === null || t[key] === null || !Number.isSafeInteger(n)
					? null
					: n;
		}
		this.models.set(group, subtotal);
		this.observedAt = Date.now();
		this.observed.set(group, this.observedAt);
		for (const k of Object.keys(t) as (keyof Tokens)[]) {
			if (t[k] === null || this.totals[k] === null) {
				this.totals[k] = null;
				this.reasons.add("missing-usage");
			} else {
				const n = this.totals[k]! + t[k]!;
				this.totals[k] = Number.isSafeInteger(n) ? n : null;
			}
		}
	}
	markPartial(reason: string) {
		if (/^[a-z-]{1,64}$/.test(reason) && this.reasons.size < 16)
			this.reasons.add(reason);
	}
	reports(): UsageReport[] {
		const base = this.report();
		return this.models.size
			? [...this.models].map(([model, tokens]) => ({
					...base,
					model,
					tokens: { ...tokens },
					observedAt: this.observed.get(model) ?? null,
				}))
			: [base];
	}
	report(): UsageReport {
		return {
			source: "pi.turn_end",
			scope: "attachment-window",
			windowId: this.windowId,
			startedAt: this.startedAt,
			observedAt: this.observedAt,
			coverage: "partial",
			tokens: this.consumed ? { ...this.totals } : emptyTokens(),
			cost: null,
			unresolvedChildren: null,
			includedRunIds: [],
			reasons: [...this.reasons],
		};
	}
}
export function costProjection(
	raw: unknown,
	windowId: string,
	startedAt: number | null,
): UsageReport | undefined {
	if (
		!object(raw) ||
		raw.version !== 1 ||
		!object(raw.total) ||
		!Array.isArray(raw.children)
	)
		return undefined;
	const unresolved =
		Number.isSafeInteger(raw.unresolvedAsyncChildren) &&
		Number(raw.unresolvedAsyncChildren) >= 0
			? Number(raw.unresolvedAsyncChildren)
			: null;
	const ids = raw.children
		.slice(0, 128)
		.flatMap((c) => (object(c) && safeId(c.runId) ? [c.runId] : []));
	const total = tokens(raw.total);
	const valid = Object.values(total).every((v) => v !== null);
	return {
		source: "subagents.cost.v1",
		observedAt: Date.now(),
		scope: "owner-session-total",
		windowId,
		startedAt,
		coverage:
			unresolved !== 0 || !valid || ids.length !== raw.children.length
				? "partial"
				: "owner-reported",
		tokens: total,
		cost:
			typeof raw.total.cost === "number" &&
			Number.isFinite(raw.total.cost) &&
			raw.total.cost >= 0
				? raw.total.cost
				: null,
		unresolvedChildren: unresolved,
		includedRunIds: [...new Set(ids)],
		accountingGroup: windowId,
		reasons:
			unresolved === null
				? ["child-coverage-unavailable"]
				: unresolved > 0
					? ["unresolved-children"]
					: [],
	};
}
