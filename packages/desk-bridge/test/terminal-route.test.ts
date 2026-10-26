import assert from "node:assert/strict";
import { test } from "node:test";
import { routeFromMetadata } from "../src/terminal-route.ts";
import { validate } from "../src/protocol.ts";
import { sessionCreatedAt } from "../src/session.ts";

test("terminal route keeps exact tty/session metadata and never falls back to cwd", () => {
  const route = routeFromMetadata("session-a", "/private/session-a.jsonl", "/private/project", {
    TERM_PROGRAM: "Apple_Terminal", TERM_SESSION_ID: "session-tty-a", TMUX_PANE: "%7",
  }, "/dev/ttys034");
  assert.equal(route.kind, "terminal");
  assert.equal(route.ttyPath, "/dev/ttys034");
  assert.equal(route.terminalApp, "com.apple.Terminal");
  assert.equal(route.terminalSessionId, "session-tty-a");
  assert.equal(route.tmuxPane, "%7");
  assert.equal(route.cwd, "/private/project");
});

test("invalid tty is unavailable instead of choosing a terminal by cwd", () => {
  const route = routeFromMetadata("session-b", "/private/session-b.jsonl", "/private/project", { TERM_PROGRAM: "Apple_Terminal" }, "/dev/random");
  assert.equal(route.kind, "unavailable");
  assert.equal(route.ttyPath, undefined);
  assert.equal(route.cwd, "/private/project");
});

test("session header creation timestamp is scalar and unknown-safe", () => {
  assert.deepEqual(sessionCreatedAt("2026-10-26T15:21:00.000Z"), { createdAt: Date.parse("2026-10-26T15:21:00.000Z"), source: "session-header" });
  assert.deepEqual(sessionCreatedAt("not-a-date"), { createdAt: null, source: "unknown" });
  assert.deepEqual(sessionCreatedAt("+100000-01-01T00:00:00.000Z"), { createdAt: null, source: "unknown" });
});

test("route and createdAt validation reject unsafe fields", () => {
  const base = { version: 1, kind: "hello", identity: { localHostId: "host", nativeSessionId: "session", runtimeEpoch: "epoch" }, snapshot: { identity: { localHostId: "host", nativeSessionId: "session", runtimeEpoch: "epoch" }, seq: 1, observedAt: 1, capabilities: { actions: [], queries: [], owners: {} }, display: { name: "Pi", mode: "tui", createdAt: 1, createdAtSource: "session-header", route: { kind: "terminal", sessionId: "session", ttyPath: "/dev/ttys034" } }, execution: "unknown", pending: null, childCoverage: "unknown", tools: [], runs: [], schedules: [], usage: [], inputs: [], evidence: [], dropped: 0, contextTokens: null } } as any;
  validate(base);
  const snapshot = base.snapshot!;
  assert.throws(() => validate({ ...base, snapshot: { ...snapshot, display: { ...snapshot.display, createdAt: 8_640_000_000_000_001 } } }));
  assert.throws(() => validate({ ...base, snapshot: { ...snapshot, display: { ...snapshot.display, route: { ...snapshot.display.route, ttyPath: "/dev/random" } } } }));
});

test("Herdr metadata remains separate from terminal route", () => {
  const route = routeFromMetadata("session-c", "/private/session-c.jsonl", "/private/project", { HERDR_PANE_ID: "pane-a" }, "/dev/ttys034");
  assert.equal(route.kind, "herdr");
  assert.equal(route.ttyPath, "/dev/ttys034");
});
