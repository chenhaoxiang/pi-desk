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
	const previous = server;
	previous.kill("SIGKILL");
	await new Promise((r) => previous.once("exit", r));
	await Promise.all([
		a.session.prompt("continues without app"),
		b.session.prompt("independent continues"),
	]);
	assert.equal(a.faux.state.callCount, 2);
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
	assert.equal(a.faux.state.callCount, 2);
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
