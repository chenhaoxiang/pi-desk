import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { TodoObserver, validTodoProjection } from "../src/todo-projection.ts";
import { displayBudget } from "../src/budget.ts";
import { encode, validate, type RecordV1 } from "../src/protocol.ts";
const fixture = JSON.parse(readFileSync(new URL("../../../Fixtures/todo-v1.json", import.meta.url), "utf8"));
const result = (tasks: unknown[], action = "list") => ({ details: { action, tasks, params: { PRIVATE: "must not project" }, nextId: 4 }, content: [{ text: "PRIVATE_TOOL_BODY" }] });
const rows = [
  { id: 1, subject: "需求", status: "completed", description: "PRIVATE_DESCRIPTION", metadata: { secret: "PRIVATE_METADATA" } },
  { id: 2, subject: "实现", activeForm: "接入当前任务", status: "in_progress", blockedBy: [1] },
  { id: 3, subject: "验证", status: "pending", blockedBy: [2, 99] },
];
test("shared Todo golden is valid and remains optional for legacy wire", () => {
  assert.ok(validTodoProjection(fixture));
  const wire: RecordV1 = JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json", import.meta.url), "utf8"));
  validate(wire); wire.snapshot!.todo = fixture; validate(wire); assert.ok(encode(wire).length < 65536);
});
test("success metadata is projected, not tool text or another task database", () => {
  const observer = new TodoObserver(); assert.equal(observer.read().coverage, "not-observed"); assert.equal(observer.read().counts, undefined);
  const raw = result(rows), before = JSON.stringify(raw);
  observer.start("call-1"); assert.ok(observer.end("call-1", raw, false, 1000));
  const snapshot = observer.read(); assert.ok(validTodoProjection(snapshot));
  assert.deepEqual(snapshot.counts, { pending: 1, inProgress: 1, completed: 1, total: 3 });
  assert.deepEqual(snapshot.tasks[0].unresolvedBy, []);
  assert.deepEqual(snapshot.tasks[1].unresolvedBy, [2, 99]);
  assert.equal(JSON.stringify(raw), before); assert.ok(!JSON.stringify(snapshot).includes("PRIVATE"));
  assert.equal(observer.end("call-1", raw, false, 1000), false, "duplicate end is not a new task update");
  observer.start("failed"); observer.end("failed", { ...raw, isError: true }, false, 1001); assert.deepEqual(observer.read(), snapshot);
});
test("branch and clear scopes reject late snapshots and reset reused task IDs", () => {
  const o = new TodoObserver(); o.start("old"); const oldScope = o.read().scope; o.reset();
  assert.notEqual(o.read().scope, oldScope); assert.equal(o.end("old", result(rows), false, 1000), false); assert.equal(o.read().coverage, "not-observed");
  o.start("new"); o.end("new", result(rows), false, 1000); const scope = o.read().scope;
  o.start("clear"); o.end("clear", result([], "clear"), false, 1001);
  assert.notEqual(o.read().scope, scope); assert.equal(o.read().counts?.total, 0); assert.equal(o.read().coverage, "observed");
});
test("overlapping snapshots without a native revision are unavailable until an uncontested result", () => {
  const o = new TodoObserver(); o.start("a"); o.start("b");
  assert.equal(o.read().coverage, "unavailable");
  assert.equal(o.end("b", result(rows), false, 1000), false);
  assert.equal(o.end("a", result(rows), false, 1001), false);
  o.start("c"); assert.ok(o.end("c", result(rows), false, 1002)); assert.equal(o.read().coverage, "observed");
});
test("malformed and oversized source is explicitly unavailable; metadata never executes getters", () => {
  const o = new TodoObserver(); let getters = 0;
  const evil = { id: 1, status: "pending", get subject() { getters++; return "PRIVATE"; } };
  o.start("getter"); o.end("getter", result([evil]), false, 1000); assert.equal(getters, 0);
  o.start("too-many"); o.end("too-many", result(Array(513).fill(rows[0])), false, 1001);
  assert.equal(o.read().coverage, "unavailable"); assert.equal(o.read().counts, undefined);
  assert.ok(validTodoProjection(o.read()));
});
test("truncated dependencies prioritize genuinely unmet references, not omission as blocking", () => {
  const o = new TodoObserver();
  const prerequisites = Array.from({length:17}, (_,i) => ({id:i+1,subject:"prior",status:"completed"}));
  const task = {id:18,subject:"next",status:"pending",blockedBy:prerequisites.map(t=>t.id)};
  o.start("satisfied"); o.end("satisfied", result([...prerequisites,task]), false, 1000);
  assert.equal(o.read().tasks[0].omittedDependencies, 1); assert.deepEqual(o.read().tasks[0].unresolvedBy, []);
  prerequisites[16].status = "pending";
  o.start("unmet"); o.end("unmet", result([...prerequisites,task]), false, 1001);
  assert.deepEqual(o.read().tasks.find(t=>t.id===18)?.unresolvedBy,[17]);
});
test("absolute paths and sparse subjects never claim complete text coverage", () => {
  const o = new TodoObserver();
  for (const subject of ["/etc/private", "路径(/opt/private)", "C:\\fixture\\private", undefined]) {
    o.start("private"); o.end("private", result([{id: 1, status: "pending", subject}]), false, 1000);
    assert.equal(o.read().coverage, "partial"); assert.ok(!JSON.stringify(o.read()).includes("private"));
  }
});
test("task rows/text/frame budget are bounded and sensitive labels withheld", () => {
  const o = new TodoObserver();
  const many = Array.from({ length: 512 }, (_, i) => ({ id: i + 1, subject: "任务".repeat(100), activeForm: "进行".repeat(100), status: i === 511 ? "in_progress" : "pending", owner: "owner" }));
  many[0].subject = "Authorization: Bearer synthetic_secret_value";
  o.start("budget"); o.end("budget", result(many), false, 1000);
  const value = o.read(); assert.ok(validTodoProjection(value)); assert.equal(value.coverage, "partial");
  assert.equal(value.tasks[0].id, 512); assert.ok(value.tasks.length <= 32); assert.equal(value.omitted + value.tasks.length, 512);
  assert.ok(Buffer.byteLength(JSON.stringify(value)) < 8192); assert.ok(!JSON.stringify(value).includes("synthetic_secret"));
  const wire: RecordV1 = JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json", import.meta.url), "utf8"));
  wire.snapshot!.todo = value; wire.snapshot = displayBudget(wire.snapshot!); assert.ok(encode(wire).length < 65536);
});
