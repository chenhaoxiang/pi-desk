import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile, access } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { OwnerRPC } from "../packages/desk-bridge/src/owners.ts";
import {
	createHost,
	ai,
	until,
	bindFixturePeerImports,
} from "./native-host.mjs";
if (!process.env.PI_DESK_SUBAGENTS)
	throw Error("PI_DESK_SUBAGENTS must name a reviewed owner package");
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/subagents-"));
const agentDir = join(root, "A", "agent");
await mkdir(join(agentDir, "extensions/subagent"), { recursive: true });
await mkdir(join(root, "os-tmp"));
process.env.TMPDIR = join(root, "os-tmp");
process.env.PI_CODING_AGENT_DIR = agentDir;
process.env.PI_SUBAGENTS_TEMP_ROOT = join(root, "owner-runtime");
delete process.env.PI_SUBAGENT_CHILD;
await writeFile(
	join(agentDir, "extensions/subagent/config.json"),
	JSON.stringify({
		defaultModel: "inherit",
		defaultThinking: "off",
		intercomBridge: { mode: "off" },
	}),
);
bindFixturePeerImports();
const { default: subagents } = await import(
	pathToFileURL(join(process.env.PI_DESK_SUBAGENTS, "index.js")).href
);
const completionEvents = new Set();
let receive;
const records = [];
let own;
let independent;
let rpc;
let release;
let registered;
let required;
let completed = false;
try {
	own = await createHost(root, "A", {
		bridge: registerBridge,
		extensions: [subagents],
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
	own.api.events.on("subagent:async-complete", (event) => {
		if (event?.runId) completionEvents.add(event.runId);
	});
	own.api.events.on("subagents:rpc:v1:request", (request) => {
		const off = own.api.events.on(
			"subagents:rpc:v1:reply:" + request.requestId,
			(reply) => {
				off();
				if (!reply.success)
					console.log(
						JSON.stringify({ method: request.method, ownerError: reply.error }),
					);
			},
		);
	});
	independent = await createHost(root, "B");
	independent.faux.setResponses([
		ai.fauxAssistantMessage("UNRELATED_SESSION_OK"),
	]);
	const registration = {
		version: 1,
		name: "desk-fixture",
		definition: {
			description: "Synthetic Pi Desk contract fixture",
			systemPrompt: "Return a synthetic value.",
			tools: [],
			model: "inherit",
		},
	};
	own.api.events.emit("pi-subagents:runtime-agent-register:v1", registration);
	assert.equal(registration.result?.ok, true);
	const providerExtension = join(root, "child-provider.ts");
	const aiURL = pathToFileURL(
		resolve(process.env.PI_DESK_SDK, "../pi-ai/dist/index.js"),
	).href;
	await writeFile(
		providerExtension,
		"import {existsSync,writeFileSync} from 'node:fs'; import {fauxProvider,fauxAssistantMessage} from " +
			JSON.stringify(aiURL) +
			"; export default pi=>{const f=fauxProvider({provider:'desk-fixture-A',models:[{id:'faux'}],tokensPerSecond:100000});f.setResponses(Array.from({length:8},()=>async(_ctx,options)=>{writeFileSync(" +
			JSON.stringify(join(root, "child-ready")) +
			",'ready');const deadline=Date.now()+20000;while(existsSync(" +
			JSON.stringify(join(root, "hold")) +
			")&&Date.now()<deadline&&!options?.signal?.aborted)await new Promise(r=>setTimeout(r,20));return fauxAssistantMessage('CHILD_SYNTHETIC_OK');}));pi.registerProvider(f.provider);};",
	);
	const { registerRequiredChildExtensions } = await import(
		pathToFileURL(
			join(
				process.env.PI_DESK_SUBAGENTS,
				"src/api/required-child-extensions.js",
			),
		).href
	);
	required = registerRequiredChildExtensions({
		sessionId: own.session.sessionId,
		extensions: [{ id: "fixture-faux-only", path: providerExtension }],
		requireForAllRunners: true,
	});
	registered = registration;
	own.faux.setResponses(
		Array.from({ length: 8 }, () => ai.fauxAssistantMessage("NATIVE_CHILD_OK")),
	);
	rpc = new OwnerRPC(own.api.events, "subagents:rpc:v1", 10000);
	const ping = await rpc.call("ping");
	assert.equal(ping.capabilities.nonRecoveringSteer, true);
	const spawned = await rpc.call("spawn", {
		script:
			"const result = await runs.run('fixture', {agent:'desk-fixture',task:'Synthetic fixture only',model:'inherit'}); return {ok:result.ok};",
		async: true,
		cwd: join(root, "A"),
	});
	assert.ok(spawned.details);
	console.log(
		JSON.stringify({
			stage: "spawn-receipt",
			mode: spawned.details.mode,
			detailKeys: Object.keys(spawned.details),
		}),
	);
	await until(async () => {
		const status = await rpc.call("status");
		return status.asyncSnapshot.runs.some(
			(r) => r.id === spawned.details.asyncId,
		);
	}, 20000);
	const firstId = spawned.details.asyncId;
	await until(async () => {
		const status = await rpc.call("status");
		return status.asyncSnapshot.runs.some(
			(r) => r.id === firstId && r.state === "complete",
		);
	}, 15000).catch(async (error) => {
		const status = await rpc.call("status", { id: firstId });
		console.log(JSON.stringify({ nativeOwnerFailure: status }));
		throw error;
	});
	const status = await rpc.call("status");
	assert.equal(status.fleet.version, 1);
	assert.equal(status.asyncSnapshot.version, 1);
	const cost = await rpc.call("cost");
	assert.equal(cost.version, 1);
	assert.equal(cost.total.input, cost.parent.input + cost.childTotal.input);
	// A second real owner workflow holds in a synthetic provider; it is not a process mock.
	await writeFile(join(root, "hold"), "hold");
	own.faux.setResponses(
		Array.from({ length: 16 }, () => ai.fauxAssistantMessage("OWNER_NOTICE")),
	);
	const second = await rpc.call("spawn", {
		script:
			"const result = await runs.run('held', {agent:'desk-fixture',task:'Hold synthetic fixture',model:'inherit'}); return {ok:result.ok};",
		async: true,
		cwd: join(root, "A"),
	});
	const runId = second.details.asyncId;
	assert.ok(runId);
	// The GUI now queries only its explicitly viewed current workflow. Turn
	// boundaries must not silently read owner artifacts for this projection.
	await new Promise(r => setTimeout(r, 1600));
	receive({version:1,kind:"query",identity:records.at(-1).identity,requestId:"selected-held-workflow",query:"refresh",target:{owner:"subagents",runId}});
	await until(
		() =>
			records.some((r) =>
				r.snapshot?.runs.some(
					(run) =>
						run.parentRunId === runId && run.actions.includes("run.steer"),
				),
			),
		15000,
	);
	const child = records
		.filter((r) =>
			r.snapshot?.runs.some(
				(run) => run.parentRunId === runId && run.actions.includes("run.steer"),
			),
		)
		.at(-1)
		.snapshot.runs.find(
			(run) => run.parentRunId === runId && run.actions.includes("run.steer"),
		);
	const identity = records.at(-1).identity;
	receive({
		version: 1,
		kind: "action",
		identity,
		issuedAt: Date.now(),
		requestId: "steer-native-owner",
		action: "run.steer",
		target: { owner: "subagents", runId: child.runId },
		parameters: { text: "Synthetic correction", mode: "steer" },
	});
	await until(() => records.some((r) => r.requestId === "steer-native-owner"));
	assert.notEqual(
		records.find((r) => r.requestId === "steer-native-owner").result.status,
		"rejected",
	);
	const action = {
		version: 1,
		kind: "action",
		identity,
		issuedAt: Date.now(),
		requestId: "stop-native-owner",
		action: "run.stop",
		target: { owner: "subagents", runId },
	};
	receive(action);
	receive(action);
	await until(() => records.some((r) => r.requestId === action.requestId));
	const stopReceipt = records.find((r) => r.requestId === action.requestId);
	if (stopReceipt.result.status !== "accepted") {
		console.log(
			JSON.stringify({
				stopResult: stopReceipt.result,
				run: records
					.filter((r) => r.snapshot?.runs.some((run) => run.runId === runId))
					.at(-1)
					?.snapshot?.runs.find((run) => run.runId === runId),
			}),
		);
	}
	assert.equal(stopReceipt.result.status, "accepted");
	assert.equal(stopReceipt.result.code, "stop-requested");
	release?.();
	await until(async () => {
		const status = await rpc.call("status");
		return status.asyncSnapshot.runs.some(
			(r) => r.id === runId && !["running", "queued"].includes(r.state),
		);
	}, 15000);
	receive({
		...action,
		requestId: "expired-target",
		target: { owner: "subagents", runId: "does-not-exist" },
	});
	await until(() => records.some((r) => r.requestId === "expired-target"));
	assert.equal(
		records.find((r) => r.requestId === "expired-target").result.status,
		"rejected",
	);
	await until(() => completionEvents.has(runId), 15000);
	await own.session.waitForIdle();
	await new Promise(r => setTimeout(r,1600));
	receive({version:1,kind:"query",identity,requestId:"selected-stopped-workflow",query:"refresh",target:{owner:"subagents",runId}});
	await independent.session.prompt(
		"Independent session continues after other run stop",
	);
	assert.equal(
		independent.session.getLastAssistantText(),
		"UNRELATED_SESSION_OK",
	);
	await until(
		() =>
			records.some((r) =>
				r.snapshot?.runs.some(
					(run) =>
						run.runId === runId &&
						run.state === "stopped" &&
						!run.actions.includes("run.resume"),
				),
			),
		15000,
	);
	receive({
		...action,
		requestId: "stopped-resume-refused",
		issuedAt: Date.now(),
		action: "run.resume",
		parameters: { text: "Try original stopped target" },
	});
	await until(() =>
		records.some((r) => r.requestId === "stopped-resume-refused"),
	);
	assert.equal(
		records.find((r) => r.requestId === "stopped-resume-refused").result.status,
		"rejected",
	);
	await assert.rejects(
		rpc.call("resume", {
			id: runId,
			message: "Do not replace stopped fixture",
		}),
	);
	await rm(join(root, "child-ready"), { force: true });
	const pausedLaunch = await rpc.call("spawn", {
		agent: "desk-fixture",
		task: "Synthetic checkpoint and resume",
		async: true,
		cwd: join(root, "A"),
	});
	const pausedId = pausedLaunch.details.asyncId;
	await until(async () => {
		const status = await rpc.call("status");
		return status.asyncSnapshot.runs.some(
			(r) => r.id === pausedId && r.state === "running",
		);
	}, 15000);
	await until(
		() =>
			access(join(root, "child-ready")).then(
				() => true,
				() => false,
			),
		15000,
	);
	await rpc.call("interrupt", { id: pausedId });
	await until(() => completionEvents.has(pausedId), 15000);
	await own.session.waitForIdle();
	await rm(join(root, "hold"));
	await new Promise(r => setTimeout(r,1600));
	receive({version:1,kind:"query",identity,requestId:"selected-paused-run",query:"refresh",target:{owner:"subagents",runId:pausedId}});
	await until(
		() =>
			records.some((r) =>
				r.snapshot?.runs.some(
					(run) =>
						run.runId === pausedId &&
						run.state === "paused" &&
						run.actions.includes("run.resume"),
				),
			),
		15000,
	);
	receive({
		...action,
		target: { owner: "subagents", runId: pausedId },
		requestId: "resume-native-owner",
		issuedAt: Date.now(),
		action: "run.resume",
		parameters: { text: "Resume this synthetic owned fixture" },
	});
	await until(
		() => records.some((r) => r.requestId === "resume-native-owner"),
		15000,
	);
	const resumeReceipt = records.find(
		(r) => r.requestId === "resume-native-owner",
	).result;
	if (resumeReceipt.status === "rejected" || resumeReceipt.status === "unknown")
		console.log(JSON.stringify({ resumeReceipt }));
	assert.equal(resumeReceipt.status, "accepted");
	assert.ok(resumeReceipt.ownerRef);
	await until(() => completionEvents.has(resumeReceipt.ownerRef), 15000);
	await own.session.waitForIdle();
	// Foreground in-process child remains a display-only Fleet relation.
	await writeFile(join(root, "hold"), "hold");
	own.session.setActiveToolsByName(["subagent"]);
	own.faux.setResponses([
		ai.fauxAssistantMessage(
			ai.fauxToolCall("subagent", {
				agent: "desk-fixture",
				task: "Synthetic foreground child",
				async: false,
			}),
			{ stopReason: "toolUse" },
		),
		ai.fauxAssistantMessage("FOREGROUND_PARENT_DONE"),
	]);
	const foreground = own.session.prompt(
		"Run this authorized synthetic foreground fixture",
	);
	await until(async () => {
		const status = await rpc.call("status");
		return status.fleet.entries.length > 0;
	}, 15000);
	receive({
		version: 1,
		kind: "query",
		identity,
		requestId: "foreground-status",
		query: "refresh",
	});
	await until(
		() =>
			records.some((r) =>
				r.snapshot?.runs.some(
					(run) => run.key.startsWith("fleet-") && !run.runId,
				),
			),
		15000,
	);
	await rm(join(root, "hold"));
	await foreground;
	assert.equal(own.session.getLastAssistantText(), "FOREGROUND_PARENT_DONE");
	const workflowPath = join(root, "synthetic-plan.js");
	await writeFile(workflowPath, "return {fixture:true};");
	own.faux.setResponses([
		ai.fauxAssistantMessage(
			ai.fauxToolCall("subagent", {
				action: "schedule.create",
				id: "desk-plan",
				workflow: workflowPath,
				options: { every: "1h", sessionOnly: false },
			}),
			{ stopReason: "toolUse" },
		),
		ai.fauxAssistantMessage("PLAN_CREATED"),
	]);
	await own.session.prompt(
		"Create one isolated synthetic plan; do not trigger it",
	);
	receive({
		version: 1,
		kind: "query",
		identity,
		requestId: "plans-refresh",
		query: "schedules.refresh",
	});
	await until(
		() =>
			records.some((r) =>
				r.snapshot?.schedules.some(
					(plan) =>
						plan.owner === "subagents" && plan.scheduleId === "desk-plan",
				),
			),
		15000,
	).catch(async (error) => {
		console.log(
			JSON.stringify({
				planDiagnostic: own.session.messages
					.filter((m) => m.role === "toolResult")
					.slice(-1),
				ownerList: await rpc.call("manage", { action: "schedule.list" }),
			}),
		);
		throw error;
	});
	receive({
		version: 1,
		kind: "action",
		identity,
		requestId: "pause-subagents-plan",
		issuedAt: Date.now(),
		action: "schedule.pause",
		target: { owner: "subagents", scheduleId: "desk-plan" },
	});
	await until(() =>
		records.some((r) => r.requestId === "pause-subagents-plan"),
	);
	assert.equal(
		records.find((r) => r.requestId === "pause-subagents-plan").result.status,
		"accepted",
	);
	const listed = await rpc.call("manage", { action: "schedule.list" });
	assert.equal(
		listed.details.schedules.records.find((p) => p.id === "desk-plan").paused,
		true,
	);
	await rpc.call("manage", { action: "schedule.delete", id: "desk-plan" });
	completed = true;
	console.log(
		JSON.stringify({
			ok: true,
			stopThroughRealOwner: true,
			foregroundOwnerProjection: true,
			subagentSchedulePause: true,
			steerThroughRealOwner: true,
			resumeThroughRealOwner: true,
			stopReceiptSeparateFromTerminal: true,
			displayKeysNotControl: true,
			realOwner: "pi-subagents",
			realSDKChild: true,
			realProviderCalls: 0,
			nativeFauxRequests: own.faux.state.callCount,
			ownerCostVersion: cost.version,
		}),
	);
	registration.result.registration.dispose();
} finally {
	release?.();
	required?.dispose();
	rpc?.close();
	if (registered?.result?.ok) registered.result.registration.dispose();
	if (own) await own.close();
	if (independent) await independent.close();
	await rm(root, { recursive: true, force: true });
}
