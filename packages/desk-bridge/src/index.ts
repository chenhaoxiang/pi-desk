import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { DeskSession, type SessionOptions } from "./session.ts";
// No resources, model tools, policy, prompt or configuration changes in the factory.
export function registerBridge(
	pi: ExtensionAPI,
	options: SessionOptions = {},
): void {
	let session: DeskSession | undefined;
	const observe = (fn: () => void): void => {
		try {
			fn();
		} catch {
			try {
				session?.observationFault();
			} catch {
				/* Observation cannot transform a turn. */
			}
		}
	};
	pi.on("session_start", (_e, ctx) => {
		session?.close();
		try {
			session = new DeskSession(pi, ctx, options);
		} catch {
			session = undefined;
		}
	});
	pi.on("session_shutdown", () => {
		session?.close();
		session = undefined;
	});
	pi.on("agent_start", (_e, ctx) => {
		observe(() => session?.lifecycle("agent_start", ctx));
	});
	pi.on("agent_end", (_e, ctx) => {
		observe(() => session?.lifecycle("agent_end", ctx));
	});
	pi.on("agent_settled", (e, ctx) => {
		observe(() => session?.lifecycle("agent_settled", ctx, e.aborted));
	});
	pi.on("model_select", (_e, ctx) => {
		observe(() => session?.observe(ctx));
	});
	pi.on("tool_execution_start", (e, ctx) => {
		observe(() => session?.tool(true, e.toolCallId, e.toolName, ctx));
	});
	pi.on("tool_execution_end", (e, ctx) => {
		observe(() => session?.tool(false, e.toolCallId, e.toolName, ctx));
	});
	pi.on("turn_end", (e, ctx) => {
		observe(() => session?.turn(e, ctx));
	});
	pi.on("ui_prompt_start", (e) => {
		observe(() => session?.prompt(true, e.kind));
	});
	pi.on("ui_prompt_end", (e) => {
		observe(() => session?.prompt(false, e.kind));
	});
}
export default function deskBridge(pi: ExtensionAPI): void {
	registerBridge(pi);
}
