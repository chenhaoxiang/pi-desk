import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { spawn } from "node:child_process";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, ai, until } from "./native-host.mjs";
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/socket-"));
await mkdir(join(root, "run"), { mode: 0o700 });
process.env.PI_DESK_SOCKET = join(root, "run", "desk.sock");
process.env.PI_DESK_PEER_CHECK = resolve(".build/debug/PiDeskPeerCheck");
const events = [];
let server;
let stderr = "";
const hosts = [];
async function start() {
	server = spawn(
		resolve(".build/debug/PiDeskTransportTests"),
		["--serve", process.env.PI_DESK_SOCKET],
		{ stdio: ["pipe", "pipe", "pipe"] },
	);
	let carry = "";
	server.stdout.on("data", (b) => {
		carry += String(b);
		while (carry.includes("\n")) {
			const i = carry.indexOf("\n");
			const line = carry.slice(0, i);
			carry = carry.slice(i + 1);
			events.push(JSON.parse(line));
			if (events.length > 1024) events.shift();
		}
	});
	server.stderr.on("data", (b) => {
		stderr += String(b).slice(0, 2000);
	});
	await until(() => events.some((e) => e.event === "socket-ready"));
}
function send(record) {
	server.stdin.write(JSON.stringify(record) + "\n");
}
const records = () =>
	events.filter((e) => e.event === "record").map((e) => e.record);
try {
	await start();
	for (const name of ["A", "B"]) {
		const h = await createHost(root, name, { bridge: registerBridge });
		hosts.push(h);
		h.faux.setResponses(
			Array.from({ length: 8 }, () => ai.fauxAssistantMessage("FIXTURE_OK")),
		);
	}
	await until(
		() => new Set(records().map((r) => r.identity.nativeSessionId)).size === 2,
	);
	const [a, b] = hosts;
	a.session.setSessionName("Pi /name 合成明确标题");
	await until(() => records().some(r => r.identity.nativeSessionId === a.session.sessionId && r.snapshot?.display.name === "Pi /name 合成明确标题"));
	assert.equal(a.faux.state.callCount, 0, "native rename projection does not invoke a model");
	const identity = records().find(
		(r) => r.identity.nativeSessionId === a.session.sessionId,
	).identity;
	const action = {
		version: 1,
		kind: "action",
		identity,
		requestId: "socket-send-1",
		issuedAt: Date.now(),
		action: "session.message",
		target: { owner: "pi" },
		parameters: { text: "fixture native request", mode: "followUp" },
	};
	send(action);
	send(action);
	await until(() => a.faux.state.callCount === 1);
	await until(() => records().some((r) => r.requestId === "socket-send-1"));
	assert.equal(b.faux.state.callCount, 0);
	assert.equal(
		records().find((r) => r.requestId === "socket-send-1").result.status,
		"requested",
	);
	await a.session.waitForIdle();
	const businessHistory = JSON.stringify(a.session.messages), businessModel = a.session.model, businessThinking = a.session.thinkingLevel;
	let virtualRoutes = 0;
	const aliasID = "virtual-ai-alias", aliasProvider = a.faux.getModel("faux").provider;
	a.services.modelRuntime.registerVirtualModel({ provider: aliasProvider, id: aliasID, name: "Synthetic alias", thinkingLevels: ["medium"], route() { virtualRoutes++; return { model: a.faux.getModel("faux"), thinkingLevel: "off" }; } });
	assert.equal(a.services.modelRuntime.getModel(aliasProvider, aliasID)?.api, "pi-virtual");
	await until(() => a.services.modelRuntime.getAvailableSnapshot().some(m => m.provider === aliasProvider && m.id === aliasID));
	const aiPacket = (requestId, assistant) => ({ version: 1, kind: "assistant-request", identity, requestId, issuedAt: Date.now(), assistant });
	send(aiPacket("socket-ai-models", { operation: "models" }));
	await until(() => records().some(r => r.requestId === "socket-ai-models" && r.assistant?.status === "ok"));
	const registered = records().find(r => r.requestId === "socket-ai-models").assistant.models.find(m => m.provider.startsWith("desk-fixture-"));
	assert.ok(registered, "real SDK facade exposes its registered faux model through Swift UDS");
	assert.ok(!records().find(r => r.requestId === "socket-ai-models").assistant.models.some(m => m.provider === aliasProvider && m.modelId === aliasID), "SDK virtual aliases are not fixed-model choices");
	send(aiPacket("socket-ai-virtual", { operation: "analyze", provider: aliasProvider, modelId: aliasID, thinking: "medium", sources: [{ ref: "S1", title: "Synthetic source", project: "fixture", status: "observed", tools: [], messages: [] }] }));
	await until(() => records().some(r => r.requestId === "socket-ai-virtual" && r.assistant?.code === "model-unavailable"));
	assert.equal(virtualRoutes, 0, "reject before any virtual routing or inference");
	assert.equal(a.faux.state.callCount, 1);
	send(aiPacket("socket-ai-context", { operation: "context" }));
	await until(() => records().some(r => r.requestId === "socket-ai-context" && r.assistant?.status === "ok"));
	const context = records().find(r => r.requestId === "socket-ai-context").assistant.messages;
	assert.ok(context.some(m => m.role === "user") && context.every(m => ["user", "assistant"].includes(m.role)));
	const summary = { overview: "Synthetic UDS result", summaries: [{ ref: "S1", text: "Evidence only, not business completion" }], groups: [{ name: "Synthetic group", refs: ["S1"], reason: "Local display suggestion" }] };
	a.faux.setResponses(Array.from({ length: 12 }, () => ai.fauxAssistantMessage(JSON.stringify(summary))));
	const aiAnalysis = aiPacket("socket-ai-analysis", { operation: "analyze", provider: registered.provider, modelId: registered.modelId, thinking: registered.thinkingLevels[0], sources: [{ ref: "S1", title: "Synthetic source", project: "fixture", status: "observed", tools: [], messages: context }] });
	send(aiAnalysis); send(aiAnalysis);
	await until(() => records().some(r => r.requestId === "socket-ai-analysis" && r.assistant?.status === "ok"));
	assert.equal(a.faux.state.callCount, 2, "duplicate AI packet cannot spend twice");
	assert.equal(JSON.stringify(a.session.messages), businessHistory, "assistant inference must not enter business conversation history");
	assert.equal(a.session.model, businessModel); assert.equal(a.session.thinkingLevel, businessThinking);
	assert.equal(b.faux.state.callCount, 0);
	const previous = server;
	previous.kill("SIGKILL");
	await new Promise((r) => previous.once("exit", r));
	await Promise.all([
		a.session.prompt("continues without app"),
		b.session.prompt("independent continues"),
	]);
	assert.equal(a.faux.state.callCount, 3);
	assert.equal(b.faux.state.callCount, 1);
	events.length = 0;
	await start();
	await until(
		() =>
			new Set(
				records()
					.filter((r) => r.kind === "hello")
					.map((r) => r.identity.nativeSessionId),
			).size === 2,
		10000,
	);
	assert.equal(a.faux.state.callCount, 3);
	assert.equal(b.faux.state.callCount, 1);
	assert.deepEqual(a.errors, []);
	assert.deepEqual(b.errors, []);
	console.log(
		JSON.stringify({
			ok: true,
			transport: "real-swift-uds",
			peerUID: "verified-both-ends",
			twoNativeSessions: true,
			dedup: true,
			killReceiverPiContinues: true,
			reconnectNoReplay: true,
			nativeSessionNameUpdated: true,
			assistantRegisteredModel: true,
			assistantScopedContext: true,
			assistantDoesNotEnterBusinessHistory: true,
			assistantDedup: true,
			assistantRejectsSDKVirtualBeforeRouting: virtualRoutes === 0,
			realProviderCalls: 0,
		}),
	);
} catch (error) {
	console.log(
		JSON.stringify({
			phaseEvents: events.filter((e) => e.event !== "record").slice(-10),
			stderr,
		}),
	);
	throw error;
} finally {
	for (const h of hosts) await h.close();
	server?.stdin.end();
	if (
		server &&
		server.exitCode === null &&
		server.signalCode === null &&
		!server.killed
	) {
		await new Promise((r) => {
			server.once("exit", r);
			setTimeout(() => {
				server.kill();
				r();
			}, 1000);
		});
	}
	await rm(root, { recursive: true, force: true });
}
