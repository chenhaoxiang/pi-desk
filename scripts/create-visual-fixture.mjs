import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
const root = resolve("tmp/visual-fixtures");
await mkdir(root, { recursive: true, mode: 0o700 });
const identity = (id, epoch) => ({
	localHostId: "fixture-host",
	nativeSessionId: id,
	runtimeEpoch: epoch,
});
const common = {
	display: {
		name: "Pi",
		cwd: "/synthetic/demo-web",
		branch: "feat/navigation",
		model: "fixture/faux",
		effort: "high",
		mode: "tui",
	},
	capabilities: {
		actions: ["session.message", "session.abort-current"],
		queries: ["refresh", "usage.refresh"],
		owners: {
			pi: "extension-api-1.4",
			"pi-desk-bridge": "027572e36fc9143f1c8ade44156ded44d417c5f2",
		},
	},
	pending: false,
	childCoverage: "owner-reported",
	tools: [],
	runs: [],
	schedules: [],
	usage: [
		{
			source: "pi.turn_end",
			scope: "attachment-window",
			windowId: "fixture-window",
			model: "fixture/faux",
			observedAt: Date.now(),
			startedAt: Date.now(),
			coverage: "partial",
			tokens: {
				input: 218000,
				output: 34000,
				cacheRead: 1120000,
				cacheWrite: 0,
			},
			cost: null,
			unresolvedChildren: null,
			includedRunIds: [],
			reasons: ["attachment-only"],
		},
	],
	inputs: [],
	evidence: [],
	dropped: 0,
	contextTokens: 1200,
};
const records = [];
function add(id, epoch, seq, name, execution, extra = {}) {
	const ident = identity(id, epoch);
	const snapshot = {
		identity: ident,
		seq,
		observedAt: Date.now(),
		display: {
			name,
			cwd: "/synthetic/demo-web",
			branch: "feat/navigation",
			model: "fixture/faux",
			effort: "high",
			mode: "tui",
		},
		execution,
		...structuredClone(common),
		...extra,
	};
	records.push({
		version: 1,
		kind: seq === 1 ? "hello" : "snapshot",
		identity: ident,
		snapshot,
	});
}
add("synthetic-input", "epoch-input", 1, "官网优化", "running", {
	display: { ...common.display, name: "官网优化" },
	inputs: [
		{
			id: "input-1",
			source: "pi:input-required",
			kind: "question",
			startedAt: Date.now(),
		},
	],
});
add("synthetic-run", "epoch-run", 1, "接口联调", "running", {
	display: { ...common.display, name: "接口联调", branch: "feat/api-contract" },
	tools: ["edit"],
	runs: [
		{
			key: "child-1",
			runId: "child-run-1",
			parentRunId: "root-run",
			owner: "subagents",
			state: "running",
			agent: "reviewer",
			model: "fixture/faux",
			effort: "high",
			actions: ["run.stop", "run.steer"],
		},
	],
});
add("synthetic-done", "epoch-done", 1, "测试检查", "settled", {
	display: { ...common.display, name: "测试检查", branch: "fix/regression" },
	execution: "settled",
	usage: [
		{
			...common.usage?.[0],
			source: "pi.turn_end",
			scope: "attachment-window",
			windowId: "done-window",
			coverage: "partial",
			tokens: { input: null, output: null, cacheRead: null, cacheWrite: null },
			reasons: ["attachment-only", "not-settled"],
		},
	],
});
await writeFile(
	resolve(root, "fixture.json"),
	JSON.stringify({ synthetic: true, records }, null, 2),
	{ mode: 0o600 },
);
await writeFile(
	resolve(root, "empty.json"),
	JSON.stringify({ synthetic: true, records: [] }),
	{ mode: 0o600 },
);
const edge = structuredClone(records);
edge[0].snapshot.display.name =
	"一个很长的合成会话名称，用于验证中文长标题与多行辅助阅读不会挤坏操作按钮";
edge[1].snapshot.inputs = [];
edge[1].snapshot.execution = "unknown";
edge[2].snapshot.execution = "failed";
await writeFile(
	resolve(root, "edges.json"),
	JSON.stringify({
		synthetic: true,
		records: edge,
		connections: {
			"synthetic-input": "disconnected",
			"synthetic-run": "stale",
		},
	}),
	{ mode: 0o600 },
);
console.log(resolve(root, "fixture.json"));
