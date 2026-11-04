import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { displayBudget } from "../src/budget.ts";
import { encode, type RecordV1 } from "../src/protocol.ts";
import { TodoObserver } from "../src/todo-projection.ts";
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
	}));
	const todo = new TodoObserver(); todo.start("maximum-todo");
	todo.end("maximum-todo", { details: { action: "list", tasks: Array.from({ length: 512 }, (_, i) => ({ id: i + 1, subject: "工".repeat(100), activeForm: "步".repeat(100), owner: "人".repeat(50), status: "pending", blockedBy: Array.from({length:16}, (_, d) => d + 1) })) } }, false, 1000);
	s.todo = todo.read();
	const bounded = displayBudget(s);
	const frame = encode({ ...fixture, snapshot: bounded });
	assert.ok(frame.length <= 65537);
	assert.ok(bounded.omitted!.runs > 0);
	assert.ok(bounded.omitted!.schedules > 0);
	assert.equal(bounded.childCoverage, "partial");
	assert.equal(s.runs.length, 64);
});
