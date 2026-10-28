import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile, readdir } from "node:fs/promises";
import { resolve, join } from "node:path";
import { createHost, ai, sdk, until } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
assert.ok(process.stdin.isTTY && process.stdout.isTTY, "run only inside the owned PTY test wrapper");
assert.ok(process.env.PI_OFFLINE === "1" && process.env.PI_CODING_AGENT_DIR?.includes("/tmp/"));
await mkdir("tmp/interactive-pty", { recursive: true });
const root = await mkdtemp(resolve("tmp/interactive-pty/case-"));
const records = [];
const h = await createHost(root, "TUI", { bridge: registerBridge, transport: () => ({ start() {}, close() {}, publish(r) { records.push(r); }, reply() {}, dropped: 0 }) });
const runtime = new sdk.AgentSessionRuntime(h.session, h.services, async () => { throw Error("fixture-does-not-replace-sessions"); });
let mode, failure;
try {
  mode = new sdk.InteractiveMode(runtime, { verbose: false, tuiMode: "inline" });
  await mode.init();
  h.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_PTY_OK"), ai.fauxAssistantMessage("SYNTHETIC_PTY_CONTINUE")]);
  await h.session.prompt("Synthetic interactive PTY fixture");
  await h.session.prompt("Synthetic interactive continuation");
  await until(() => records.some(r => r.snapshot?.display.mode === "tui" && r.snapshot?.execution === "settled"));
  assert.equal(h.faux.state.callCount, 2);
  assert.equal(h.session.getLastAssistantText(), "SYNTHETIC_PTY_CONTINUE");
  assert.deepEqual(h.errors, []);
  const result = { ok: true, processHasPTY: true, actualInteractiveMode: true, nativeDisplayMode: "tui", calls: 2, realProviderCalls: 0, root };
  await writeFile(process.env.PI_DESK_TUI_RESULT, JSON.stringify(result, null, 2), { mode: 0o600 });
} catch (error) {
  failure = error;
  await writeFile(process.env.PI_DESK_TUI_RESULT, JSON.stringify({ ok: false, actualInteractiveMode: !!mode, error: String(error.message ?? error), stack: String(error.stack ?? "").slice(0, 3000), root }, null, 2), { mode: 0o600 });
} finally { mode?.stop(); await runtime.dispose(); }
process.exit(failure ? 1 : 0);
