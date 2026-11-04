import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHost, ai, until, bindFixturePeerImports } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { spawn } from "node:child_process";

await mkdir("tmp", { recursive: true });
const root = await mkdtemp(resolve("tmp/native-todo-"));
let nativeTodo;
if (process.env.PI_DESK_TODO_ROOT) {
  bindFixturePeerImports();
  nativeTodo = await import(pathToFileURL(join(process.env.PI_DESK_TODO_ROOT, "todo.ts")).href);
}
const records = [];
let server;
const socket = process.argv.includes("--socket");
if (socket) {
  await mkdir(join(root, "run"), { mode: 0o700 });
  process.env.PI_DESK_SOCKET = join(root, "run", "desk.sock");
  process.env.PI_DESK_PEER_CHECK = resolve(".build/debug/PiDeskPeerCheck");
  server = spawn(resolve(".build/debug/PiDeskTransportTests"), ["--serve", process.env.PI_DESK_SOCKET], { stdio: ["pipe", "pipe", "inherit"] });
  let carry = "", ready = false;
  server.stdout.on("data", bytes => {
    carry += String(bytes);
    while (carry.includes("\n")) {
      const end = carry.indexOf("\n"), message = JSON.parse(carry.slice(0, end)); carry = carry.slice(end + 1);
      if (message.event === "socket-ready") ready = true;
      if (message.event === "record") { records.push(message.record); if (records.length > 100) records.shift(); }
    }
  });
  await until(() => ready);
}
const fixtureTasks = [{ id: 1, subject: "合成计划", status: "completed" }, { id: 2, subject: "合成当前工作", activeForm: "验证只读投影", status: "in_progress", blockedBy: [1] }];
const contractTool = { name: "todo", label: "Synthetic Todo contract", description: "Synthetic native tool result", parameters: { type: "object", properties: { action: {type:"string"}, subject: {type:"string"}, id: {type:"number"}, status: {type:"string"} }, required:["action"] }, execute: async () => ({ content: [{ type: "text", text: "PRIVATE_TOOL_TEXT" }], details: { action: "list", tasks: fixtureTasks, nextId: 3 } }) };
const host = await createHost(root, "todo", { bridge: registerBridge,
  tools: nativeTodo ? [] : [contractTool], extensions: nativeTodo ? [(pi) => nativeTodo.registerTodoTool(pi)] : [],
  ...(socket ? {} : { transport: (_hello) => ({ start() {}, close() {}, reply() {}, publish(r) { records.push(structuredClone(r)); if(records.length>100)records.shift(); }, dropped: 0 }) }),
});
try {
  host.session.setActiveToolsByName(["todo"]);
  const before = { model: host.session.model, effort: host.session.thinkingLevel, tools: host.session.getActiveToolNames(), prompt: host.session.systemPrompt };
  const call = nativeTodo ? { action: "create", subject: "合成当前工作", activeForm: "验证只读投影" } : { action: "list" };
  host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("todo", call), { stopReason: "toolUse" }), ai.fauxAssistantMessage("SYNTHETIC_DONE")]);
  await host.session.prompt("synthetic native todo observation");
  await until(() => records.some(r => r.snapshot?.todo?.counts?.total > 0));
  const todo = records.filter(r => r.snapshot?.todo?.counts).at(-1).snapshot.todo;
  assert.equal(todo.coverage, "observed");
  assert.ok(todo.tasks.some(t => t.subject === "合成当前工作"));
  assert.ok(!JSON.stringify(todo).includes("PRIVATE_TOOL_TEXT"));
  let exercisedOwnerActions = [call.action];
  if (nativeTodo) {
    assert.equal(nativeTodo.getTodos()[0].subject, todo.tasks[0].subject, "same isolated owner instance is the original fact");
    for (const params of [{action:"create",subject:"第二项"}, {action:"get",id:1}, {action:"list",status:"completed"}, {action:"update",id:2,status:"in_progress",activeForm:"合成步骤"}, {action:"delete",id:1}, {action:"clear"}]) {
      const previous = records.filter(r => r.snapshot?.todo?.counts).at(-1).snapshot.todo.observerSeq;
      host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("todo", params), { stopReason: "toolUse" }), ai.fauxAssistantMessage("SYNTHETIC_DONE")]);
      await host.session.prompt("synthetic native todo full-state contract");
      await until(() => records.some(r => r.snapshot?.todo?.observerSeq > previous && r.snapshot.todo.counts));
      const projected = records.filter(r => r.snapshot?.todo?.counts).at(-1).snapshot.todo;
      const original = nativeTodo.getTodos().filter(t => t.status !== "deleted");
      assert.equal(projected.counts.total, original.length);
      assert.deepEqual(projected.tasks.map(t => [t.id,t.subject,t.status]).sort(), original.map(t => [t.id,t.subject,t.status]).sort(), params.action + " retains the full owner state, not a filtered subset");
      if (params.action === "get" || params.action === "list") assert.equal(projected.counts.total, 2);
      exercisedOwnerActions.push(params.action);
    }
  }
  assert.deepEqual({ model: host.session.model, effort: host.session.thinkingLevel, tools: host.session.getActiveToolNames(), prompt: host.session.systemPrompt }, before);
  assert.equal(host.faux.state.callCount, exercisedOwnerActions.length * 2); assert.deepEqual(host.errors, []);
  console.log(JSON.stringify({ ok: true, nativeSDK: true, nativeTodoOwner: nativeTodo ? "explicit-owner-source" : "synthetic-TaskDetails-contract", firstResultProjected: true, exercisedOwnerActions, realSwiftUDS: socket, loadoutUnchanged: true, addedModelCalls: 0, realProviderCalls: 0 }));
} finally {
  await host.close();
  if (server && server.exitCode === null) {
    const exited = new Promise(resolve => server.once("exit", resolve));
    const safety = setTimeout(() => server.kill(), 1000).unref();
    server.stdin.end(); await exited; clearTimeout(safety);
  }
  await rm(root, { recursive: true, force: true });
}
