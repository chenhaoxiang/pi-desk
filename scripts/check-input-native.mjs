import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, until } from "./native-host.mjs";
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/input-"));
let own;
let ask;
let answer;
let answered = false;
const records = [];
try {
	const extension = (pi) =>
		pi.on("session_start", (_e, ctx) => {
			ask = () =>
				ctx.ui.input("PRIVATE_FIXTURE_TITLE", "PRIVATE_FIXTURE_PLACEHOLDER");
		});
	const ui = new Proxy(
		{ input: () => new Promise((r) => (answer = r)) },
		{ get: (t, k) => (k in t ? t[k] : () => {}) },
	);
	own = await createHost(root, "A", {
		bridge: registerBridge,
		extensions: [extension],
		bindings: { uiContext: ui, mode: "rpc" },
		transport: () => ({
			start() {},
			publish: (r) => records.push(r),
			reply: (r) => records.push(r),
			close() {},
			dropped: 0,
		}),
	});
	const original = ask().then((value) => {
		answered = true;
		return value;
	});
	await until(() =>
		records.some((r) => r.snapshot?.inputs.some((i) => i.kind === "input")),
	);
	assert.equal(answered, false);
	assert.equal(own.faux.state.callCount, 0);
	assert.ok(!JSON.stringify(records).includes("PRIVATE_FIXTURE"));
	// There is no App answer action. Only the original owner UI resolves this promise.
	answer("SYNTHETIC_ANSWER");
	assert.equal(await original, "SYNTHETIC_ANSWER");
	await until(() => records.at(-1)?.snapshot?.inputs.length === 0);
	assert.equal(own.faux.state.callCount, 0);
	assert.deepEqual(own.errors, []);
	console.log(
		JSON.stringify({
			ok: true,
			nativeUIPromptLifecycle: true,
			rawTitleNotForwarded: true,
			originalAnswerOnly: true,
			displayModelCalls: 0,
			addedConfirmations: 0,
		}),
	);
} finally {
	if (own) await own.close();
	await rm(root, { recursive: true, force: true });
}
