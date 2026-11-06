import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { displayBudget } from "../src/budget.ts";
import { encode, type RecordV1 } from "../src/protocol.ts";
import { TodoObserver } from "../src/todo-projection.ts";
import { MissionDecisionObserver } from "../src/mission-decisions.ts";
import { IntercomRelationsObserver } from "../src/intercom-observer.ts";
import { boundGovernance } from "../src/governance-projection.ts";
test("combined maximum DTOs fit one frame and omitted records remain explicit", async () => {
	const fixture = JSON.parse(
		await readFile(
			new URL("../../../Fixtures/wire-v1.json", import.meta.url),
			"utf8",
		),
	) as RecordV1;
	const s = fixture.snapshot!;
	s.runs = Array.from({ length: 64 }, (_, i) => ({
		key: "x".repeat(120) + i,
		runId: "r".repeat(120) + i,
		parentRunId: "p".repeat(128),
		owner: "subagents",
		state: "running",
		agent: "a".repeat(128),
		model: "m".repeat(128),
		effort: "high",
		actions: ["run.stop"],
	}));
	s.schedules = Array.from({ length: 64 }, (_, i) => ({
		owner: "subagents",
		scheduleId: "s".repeat(120) + i,
		name: "中".repeat(170),
		state: "paused",
		actions: ["schedule.pause", "schedule.resume"],
	}));
	s.inputs = Array.from({ length: 32 }, (_, i) => ({
		id: "i" + i,
		source: "pi.ui_prompt",
		kind: "input",
		startedAt: 100,
		question: { version: 1 as const, binding: "declared" as const, ownerEpoch:"epoch", sequence:1, observedAt:100, workRef:{owner:"o".repeat(256),kind:"task" as const,key:"k".repeat(128)},workPhase:"p".repeat(128) },
	}));
	const todo = new TodoObserver(); todo.start("maximum-todo");
	todo.end("maximum-todo", { details: { action: "list", tasks: Array.from({ length: 512 }, (_, i) => ({ id: i + 1, subject: "工".repeat(100), activeForm: "步".repeat(100), owner: "人".repeat(50), status: "pending", blockedBy: Array.from({length:16}, (_, d) => d + 1) })) } }, false, 1000);
	s.todo = todo.read();
	const work = JSON.parse(await readFile(new URL("../../../Fixtures/work-results-v1.json", import.meta.url), "utf8"));
	work.results = Array.from({length:16}, (_,i) => ({ ...work.results[0], seq:i+1, observation:{...work.results[0].observation,resultRef:"r".repeat(128)} })); work.observerSeq=17; work.handoffs[0].seq=17;
	s.governance = boundGovernance(work);
	const decisions = new MissionDecisionObserver();
 for(let i=0;i<16;i++){
  const id="mission-"+i, details={mode:"management",missionId:id,mission:{schemaVersion:1,id,updatedAt:"2026-11-06T00:00:00.000Z",decisions:Array.from({length:512},(_,j)=>({id:"d".repeat(120)+j,status:"open",createdAt:"2026-11-06T00:00:00.000Z"}))}};
  decisions.start(id);decisions.result({toolName:"subagent",toolCallId:id,isError:false,input:{action:"mission.show",options:{missionId:id}},details});decisions.end(id,{details},false,1000);
 }
 s.missionDecisions = decisions.read();
 assert.ok(s.missionDecisions.omittedMissions>0);
 assert.ok(Buffer.byteLength(JSON.stringify(s.missionDecisions))>3000);
 const messages = new IntercomRelationsObserver();
 for(let i=0;i<16;i++){
  const messageId="m".repeat(120)+i, details={messageId,delivery:"socket_delivered",replyState:"not_requested",outcomeKnown:true,execution:"unknown",completion:"unknown",updatedAt:1000,relations:{version:1,senderSessionId:"s".repeat(128),recipientSessionId:"r".repeat(128),replyCorrelation:"late",lateReplyTo:"a".repeat(128)}};
  messages.start(messageId);messages.result({toolName:"intercom",toolCallId:messageId,isError:false,input:{action:"status",messageId},details});messages.end(messageId,{details},false,1001);
 }
 s.intercomRelations=messages.read();assert.ok(s.intercomRelations.omitted>0);
	const bounded = displayBudget(s);
	const frame = encode({ ...fixture, snapshot: bounded });
	assert.ok(frame.length <= 65537);
	assert.ok(bounded.omitted!.runs > 0);
	assert.ok(bounded.omitted!.schedules > 0);
	assert.equal(bounded.childCoverage, "partial");
	assert.equal(s.runs.length, 64);
});
