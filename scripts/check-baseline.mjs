import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { Type } from "typebox";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, ai } from "./native-host.mjs";
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/baseline-"));
async function run(bridge) {
	const trace = [];
	let confirmations = 0;
	let tools = 0;
	const original = (pi) =>
		pi.registerTool({
			name: "fixture_tick",
			label: "Fixture tick",
			description: "Original deterministic fixture",
			parameters: Type.Object({}),
			execute: async () => {
				tools++;
				return {
					content: [{ type: "text", text: "FIXTURE_TOOL_OK" }],
					details: {},
				};
			},
		});
	const host = await createHost(root, "Case", {
		bridge: bridge ? registerBridge : undefined,
		extensions: [original],
		transport: () => ({
			start() {},
			publish() {},
			reply() {},
			close() {},
			dropped: 0,
		}),
	});
	try {
		host.session.subscribe((e) => {
			if (
				[
					"agent_start",
					"tool_execution_start",
					"tool_execution_end",
					"agent_end",
					"agent_settled",
				].includes(e.type)
			)
				trace.push(e.type);
		});
		host.session.setActiveToolsByName(["fixture_tick"]);
		const parameters = {
			model: host.session.model.provider + "/" + host.session.model.id,
			effort: host.session.thinkingLevel,
			prompt: host.session.systemPrompt,
			tools: host.session.getActiveToolNames(),
		};
		host.faux.setResponses([
			ai.fauxAssistantMessage(ai.fauxToolCall("fixture_tick", {}), {
				stopReason: "toolUse",
			}),
			ai.fauxAssistantMessage("FIXTURE_DONE"),
		]);
		const time = performance.now();
		await host.session.prompt("Exact same synthetic task");
		const durationMs = performance.now() - time;
		const samples = [];
		const observationStart = performance.now();
		for (let i = 0; i < 1000; i++) {
			const start = performance.now();
			await host.session.extensionRunner.emit({
				type: "tool_execution_start",
				toolCallId: "fixture-" + i,
				toolName: "fixture_tick",
				args: { synthetic: true },
			});
			samples.push(performance.now() - start);
		}
		const observationMs = performance.now() - observationStart;
		samples.sort((a, b) => a - b);
		const observationP95 = samples[950],
			observationP99 = samples[990];
		assert.ok(observationP95 <= 1);
		assert.ok(observationP99 <= 5);
		assert.deepEqual(host.errors, []);
		return {
			trace,
			parameters,
			calls: host.faux.state.callCount,
			tools,
			confirmations,
			durationMs,
			observationMs,
			observationP95,
			observationP99,
			result: host.session.getLastAssistantText(),
		};
	} finally {
		await host.close();
	}
}
try {
	const baseline = await run(false),
		bridge = await run(true);
	const {
		durationMs: baseTime,
		observationMs: baseObservationMs,
		observationP95: _baseP95,
		observationP99: _baseP99,
		...a
	} = baseline;
	const {
		durationMs: bridgeTime,
		observationMs: bridgeObservationMs,
		observationP95: bridgeP95,
		observationP99: bridgeP99,
		...b
	} = bridge;
	assert.deepEqual(a, b);
	assert.equal(a.calls, 2);
	assert.equal(a.tools, 1);
	assert.equal(a.confirmations, 0);
	console.log(
		JSON.stringify({
			ok: true,
			sameNativeTrace: true,
			loadoutUnchanged: true,
			addedModelCalls: bridge.calls - baseline.calls,
			addedConfirmations: bridge.confirmations - baseline.confirmations,
			realProviderCalls: 0,
			baselineMs: baseTime,
			nativeObservationEvents: 1000,
			baseObservationMs,
			bridgeObservationMs,
			bridgeP95ms: bridgeP95,
			bridgeP99ms: bridgeP99,
			bridgeMs: bridgeTime,
			performanceScope: "one-synthetic-case-not-general-benchmark",
		}),
	);
} finally {
	await rm(root, { recursive: true, force: true });
}
