import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, ai, sdk, until } from "./native-host.mjs";
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/native-host-"));
let receiver;
const records = [];
let closed = 0;
const transport = (_hello, receive) => {
	receiver = receive;
	return {
		start() {},
		publish: (r) => records.push(r),
		reply: (r) => records.push(r),
		close() {
			closed++;
		},
		dropped: 0,
	};
};
const hosts = [];
try {
	const a = await createHost(root, "A", { bridge: registerBridge, transport });
	const b = await createHost(root, "B", {});
	hosts.push(a, b);
	await until(() => records.length > 0);
	assert.equal(a.faux.state.callCount, 0);
	assert.equal(b.faux.state.callCount, 0);
	const before = {
		model: a.session.model.id,
		effort: a.session.thinkingLevel,
		tools: a.session.getActiveToolNames(),
		prompt: a.session.systemPrompt,
	};
	a.faux.setResponses([
		ai.fauxAssistantMessage("A_OK"),
		ai.fauxAssistantMessage("A_FOLLOWUP"),
	]);
	b.faux.setResponses([ai.fauxAssistantMessage("B_OK")]);
	await Promise.all([
		a.session.prompt("fixture A"),
		b.session.prompt("fixture B"),
	]);
	await until(() => records.some((r) => r.snapshot?.execution === "settled"));
	const identity = records.at(-1).identity;
	const action = {
		version: 1,
		kind: "action",
		identity,
		requestId: "native-message",
		issuedAt: Date.now(),
		action: "session.message",
		target: { owner: "pi" },
		parameters: { text: "fixture follow up", mode: "followUp" },
	};
	receiver(action);
	receiver(action);
	await until(
		() =>
			a.faux.state.callCount === 2 &&
			a.session.getLastAssistantText() === "A_FOLLOWUP",
	);
	assert.equal(
		records.filter((r) => r.kind === "action-result").at(-1).result.status,
		"requested",
	);
	assert.equal(b.faux.state.callCount, 1);
	assert.deepEqual(
		{
			model: a.session.model.id,
			effort: a.session.thinkingLevel,
			tools: a.session.getActiveToolNames(),
			prompt: a.session.systemPrompt,
		},
		before,
	);
	assert.deepEqual(a.errors, []);
	assert.deepEqual(b.errors, []);
	console.log(
		JSON.stringify({
			ok: true,
			nativeSdk: true,
			twoSessions: true,
			nativeMessage: true,
			duplicateCalls: 1,
			realProviderCalls: 0,
			addedConfirmations: 0,
			loadoutUnchanged: true,
			statistics: records
				.at(-1)
				.snapshot?.usage.map((u) => ({ scope: u.scope, coverage: u.coverage })),
		}),
	);
} finally {
	for (const h of hosts) await h.close();
	await rm(root, { recursive: true, force: true });
}
