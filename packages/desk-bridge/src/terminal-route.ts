import { spawn } from "node:child_process";
import type { Snapshot } from "./protocol.ts";

type Route = NonNullable<Snapshot["display"]["route"]>;
const ttyPattern = /^\/dev\/(?:ttys[0-9A-Za-z]+|pts\/[0-9]+)$/;
const token = (value: unknown): string | undefined => typeof value === "string" && /^[A-Za-z0-9_.:%-]{1,128}$/.test(value) ? value : undefined;
export function routeFromMetadata(sessionId: string, sessionFile: string | undefined, cwd: string, env: NodeJS.ProcessEnv, ttyPath?: string): Route {
  const route: Route = { kind: env.HERDR_PANE_ID ? "herdr" : "unavailable", sessionId };
  if (sessionFile?.startsWith("/") && Buffer.byteLength(sessionFile) <= 512) route.sessionFile = sessionFile;
  if (cwd.startsWith("/") && Buffer.byteLength(cwd) <= 512) route.cwd = cwd;
  if (ttyPath && ttyPattern.test(ttyPath)) {
    route.ttyPath = ttyPath;
    if (env.TERM_PROGRAM === "Apple_Terminal") route.terminalApp = "com.apple.Terminal";
    if (env.TERM_PROGRAM === "iTerm.app") route.terminalApp = "com.googlecode.iterm2";
    if (route.kind !== "herdr" && route.terminalApp && !env.TMUX_PANE && !env.WEZTERM_PANE && !env.CMUX_SURFACE_ID) route.kind = "terminal";
  }
  route.terminalSessionId = token(env.ITERM_SESSION_ID ?? env.TERM_SESSION_ID);
  route.tmuxPane = token(env.TMUX_PANE);
  route.weztermPane = token(env.WEZTERM_PANE);
  route.cmuxWorkspace = token(env.CMUX_WORKSPACE_ID);
  route.surface = token(env.CMUX_SURFACE_ID);
  return route;
}
function fdIsTTY(fd: number): boolean {
  if (fd === 0) return process.stdin.isTTY === true;
  if (fd === 1) return process.stdout.isTTY === true;
  return process.stderr.isTTY === true;
}
async function ttyName(fd: number): Promise<string | undefined> {
  return await new Promise((resolve) => {
    const child = spawn("/usr/bin/tty", [], { stdio: [fd, "pipe", "ignore"] });
    let output = "", settled = false;
    const finish = (value?: string) => { if (settled) return; settled = true; clearTimeout(timer); resolve(value); };
    const timer = setTimeout(() => { child.kill(); finish(); }, 500).unref();
    child.stdout?.on("data", (chunk: Buffer) => { if (output.length < 128) output += chunk.toString("utf8"); });
    child.on("error", () => finish());
    child.on("exit", (code) => { const value = output.trim(); finish(code === 0 && ttyPattern.test(value) ? value : undefined); });
  });
}
export async function captureTerminalRoute(sessionId: string, sessionFile: string | undefined, cwd: string, env = process.env): Promise<Route> {
  // One deferred fd probe per attachment; never scan processes or terminal content.
  for (const fd of [0, 1, 2]) {
    if (!fdIsTTY(fd)) continue;
    const value = await ttyName(fd);
    if (value) {
      // Multiplexers need their own pane/surface focus contract. An outer
      // Terminal tab alone does not prove the original inner Pi pane is visible.
      return routeFromMetadata(sessionId, sessionFile, cwd, env, value);
    }
  }
  return routeFromMetadata(sessionId, sessionFile, cwd, env);
}
