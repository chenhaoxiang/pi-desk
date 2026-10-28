import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { Type } from "typebox";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, ai, until } from "./native-host.mjs";
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/controls-"));
const hosts = [];
try {
	let receive;
	const records = [];
	let release;
	let started = false;
	let resultReturned = false;
	const hold = (pi) =>
		pi.registerTool({
			name: "fixture_hold",
			label: "Fixture hold",
			description: "Synthetic owned task",
			parameters: Type.Object({}),
			execute: async () => {
				started = true;
				await new Promise((r) => (release = r));
				resultReturned = true;
				return {
					content: [{ type: "text", text: "FIXTURE_TOOL_OK" }],
					details: {},
				};
			},
		});
	const a = await createHost(root, "A", {
		bridge: registerBridge,
		extensions: [hold],
		transport: (_hello, recv) => {
			receive = recv;
			return {
				start() {},
				publish: (r) => records.push(r),
				reply: (r) => records.push(r),
				close() {},
				dropped: 0,
			};
		},
	});
	hosts.push(a);
	const b = await createHost(root, "B");
	hosts.push(b);
	a.session.setActiveToolsByName(["fixture_hold"]);
	a.faux.setResponses([
		ai.fauxAssistantMessage(ai.fauxToolCall("fixture_hold", {}), {
			stopReason: "toolUse",
		}),
		ai.fauxAssistantMessage("TOOL_CONTINUATION"),
		ai.fauxAssistantMessage("FOLLOWUP_DONE"),
	]);
	b.faux.setResponses([ai.fauxAssistantMessage("INDEPENDENT_DONE")]);
	const run = a.session.prompt("Fixture hold");
	await until(() => started && records.length > 0).catch((error) => {
		console.log(
			JSON.stringify({
				started,
				calls: a.faux.state.callCount,
				errors: a.errors,
				activeTools: a.session.getActiveToolNames(),
				last: a.session.messages.slice(-2),
			}),
		);
		throw error;
	});
	const identity = records.at(-1).identity;
	const action = {
		version: 1,
		kind: "action",
		identity,
		issuedAt: Date.now(),
		requestId: "followup-active",
		action: "session.message",
		target: { owner: "pi" },
		parameters: { text: "fixture followup", mode: "followUp" },
	};
	receive(action);
	await until(() =>
		a.session.getFollowUpMessages().includes("fixture followup"),
	);
	assert.equal(resultReturned, false);
	assert.equal(a.faux.state.callCount, 1);
	assert.equal(
		records.filter((r) => r.kind === "action-result").at(-1).result.status,
		"requested",
	);
	await b.session.prompt("Independent");
	assert.equal(b.session.getLastAssistantText(), "INDEPENDENT_DONE");
	release();
	await run;
	assert.equal(a.session.getLastAssistantText(), "FOLLOWUP_DONE");
	assert.equal(a.faux.state.callCount, 3);
	a.faux.setResponses([
		ai.fauxAssistantMessage(ai.fauxToolCall("fixture_hold", {}), {
			stopReason: "toolUse",
		}),
		ai.fauxAssistantMessage("STEER_DONE"),
	]);
	started = false;
	resultReturned = false;
	const steering = a.session.prompt("second fixture");
	await until(() => started);
	receive({
		...action,
		requestId: "steer-active",
		issuedAt: Date.now(),
		parameters: { text: "fixture steer", mode: "steer" },
	});
	await until(() => a.session.getSteeringMessages().includes("fixture steer"));
	assert.equal(resultReturned, false);
	release();
	await steering;
	a.faux.setResponses([
		ai.fauxAssistantMessage(ai.fauxToolCall("fixture_hold", {}), {
			stopReason: "toolUse",
		}),
	]);
	started = false;
	const stopping = a.session.prompt("abort fixture");
	await until(() => started);
	receive({
		...action,
		requestId: "abort-active",
		issuedAt: Date.now(),
		action: "session.abort-current",
		parameters: {},
	});
	await until(() => records.some((r) => r.requestId === "abort-active"));
	release();
	await stopping;
	await until(() => records.some((r) => r.snapshot?.execution === "aborted"));
	assert.equal(b.faux.state.callCount, 1);
	assert.deepEqual(a.errors, []);
	assert.deepEqual(b.errors, []);
	console.log(
		JSON.stringify({
			ok: true,
			realSDK: true,
			followUpWhileToolRuns: true,
			steerWhileToolRuns: true,
			abortTerminalObserved: true,
			independentSessionContinues: true,
			realProviderCalls: 0,
			addedConfirmations: 0,
		}),
	);
} finally {
	for (const h of hosts) await h.close();
	await rm(root, { recursive: true, force: true });
}
