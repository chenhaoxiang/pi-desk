import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import {
	createHost,
	ai,
	until,
	bindFixturePeerImports,
} from "./native-host.mjs";
if (!process.env.PI_DESK_SCHEDULE_PROMPT)
	throw Error(
		"PI_DESK_SCHEDULE_PROMPT must name the reviewed management-seam candidate",
	);
await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/schedules-"));
process.env.PI_CODING_AGENT_DIR = join(root, "A", "agent");
bindFixturePeerImports();
const ownerRoot = process.env.PI_DESK_SCHEDULE_PROMPT;
const { default: scheduleExtension } = await import(
	pathToFileURL(join(ownerRoot, "src/index.ts")).href
);
const { CronStorage } = await import(
	pathToFileURL(join(ownerRoot, "src/storage.ts")).href
);
let own;
let receive;
const records = [];
try {
	own = await createHost(root, "A", {
		bridge: registerBridge,
		extensions: [scheduleExtension],
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
	const storage = new CronStorage(join(root, "A"));
	for (const [id, session] of [
		["own", own.session.sessionId],
		["foreign", "another-session"],
	])
		storage.addJob({
			id,
			name: "Synthetic-" + id,
			type: "interval",
			schedule: "1h",
			intervalMs: 3600000,
			prompt: "PRIVATE_FIXTURE_PLAN",
			enabled: false,
			createdAt: new Date().toISOString(),
			runCount: 0,
			session,
			maxRuns: 2,
			expiresAt: new Date(Date.now() + 60000).toISOString(),
		});
	storage.addJob({
		id: "fault-own",
		name: "Synthetic uncertain delete",
		type: "interval",
		schedule: "1h",
		intervalMs: 3600000,
		prompt: "PRIVATE_FIXTURE_PLAN",
		enabled: false,
		createdAt: new Date().toISOString(),
		runCount: 0,
		session: own.session.sessionId,
	});
	storage.addJob({
		id: "event-own",
		name: "Synthetic-event",
		type: "event",
		schedule: "local:fixture",
		prompt: "PRIVATE_FIXTURE_PLAN",
		enabled: true,
		createdAt: new Date().toISOString(),
		runCount: 0,
		session: own.session.sessionId,
		maxRuns: 2,
		expiresAt: new Date(Date.now() + 60000).toISOString(),
	});
	await until(() => records.length);
	const identity = records.at(-1).identity;
	receive({
		version: 1,
		kind: "query",
		identity,
		requestId: "refresh-fixture",
		query: "schedules.refresh",
	});
	await until(
		() =>
			records.some((r) =>
				r.snapshot?.schedules.some((s) => s.scheduleId === "own"),
			),
		12000,
	);
	const snapshot = records.at(-1).snapshot;
	assert.ok(snapshot.schedules.every((s) => s.scheduleId !== "foreign"));
	assert.equal(own.faux.state.callCount, 0);
	assert.ok(!JSON.stringify(records).includes("PRIVATE_FIXTURE_PLAN"));
	const request = async (id, action, scheduleId) => {
		receive({
			version: 1,
			kind: "action",
			identity,
			requestId: id,
			issuedAt: Date.now(),
			action,
			target: { owner: "schedule-prompt", scheduleId },
		});
		await until(() => records.some((r) => r.requestId === id));
		return records.find((r) => r.requestId === id).result;
	};
	assert.equal(
		(await request("resume-own", "schedule.resume", "own")).status,
		"accepted",
	);
	assert.equal(storage.getJob("own").enabled, true);
	assert.equal(
		(await request("pause-own", "schedule.pause", "own")).status,
		"accepted",
	);
	assert.equal(storage.getJob("own").enabled, false);
	assert.equal(own.faux.state.callCount, 0);
	assert.equal(
		(await request("foreign-rejected", "schedule.pause", "foreign")).status,
		"rejected",
	);
	own.faux.setResponses([
		ai.fauxAssistantMessage("EXISTING_SCHEDULE_TRIGGERED"),
	]);
	const trigger = await request("event-trigger", "schedule.run", "event-own");
	assert.ok(["queued", "accepted"].includes(trigger.status));
	await until(() => own.faux.state.callCount === 1);
	await own.session.waitForIdle();
	assert.equal(storage.getJob("event-own").runCount, 1);
	assert.equal(own.session.messages.filter((m) => m.role === "user").length, 0);
	const originalRemove = CronStorage.prototype.removeJob;
	let uncertainEffects = 0;
	try {
		CronStorage.prototype.removeJob = function (id) {
			const removed = originalRemove.call(this, id);
			if (id === "fault-own") {
				uncertainEffects++;
				throw Error("PRIVATE_POST_MUTATION");
			}
			return removed;
		};
		const uncertain = await request(
			"uncertain-delete",
			"schedule.delete",
			"fault-own",
		);
		assert.equal(uncertain.status, "unknown");
		assert.equal(uncertain.ownerRef, "fault-own");
		assert.equal(storage.getJob("fault-own"), undefined);
		assert.equal(
			(await request("uncertain-delete", "schedule.delete", "fault-own"))
				.status,
			"unknown",
		);
		await until(
			() =>
				records.filter((r) => r.requestId === "uncertain-delete").length >= 2,
		);
		assert.ok(
			records
				.filter((r) => r.requestId === "uncertain-delete")
				.every((r) => r.result.status === "unknown"),
		);
		assert.equal(uncertainEffects, 1);
		assert.ok(!JSON.stringify(records).includes("PRIVATE_POST_MUTATION"));
	} finally {
		CronStorage.prototype.removeJob = originalRemove;
	}
	assert.deepEqual(own.errors, []);
	console.log(
		JSON.stringify({
			ok: true,
			realOwner: "pi-schedule-prompt-management-candidate",
			nativeSDK: true,
			pauseResume: true,
			postMutationUnknown: true,
			unknownDuplicateNotReplayed: true,
			foreignTargetRejected: true,
			triggerExistingEvent: true,
			noPromptInWire: true,
			displayModelCalls: 0,
			explicitSyntheticTriggerCalls: 1,
			realProviderCalls: 0,
		}),
	);
} finally {
	if (own) await own.close();
	await rm(root, { recursive: true, force: true });
}
