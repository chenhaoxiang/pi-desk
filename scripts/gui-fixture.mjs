import { mkdir, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { createHost, ai } from "./native-host.mjs";
const root = resolve("tmp/gui-runtime");
await mkdir(root, { recursive: true, mode: 0o700 });
process.env.PI_DESK_SOCKET = join(root, "desk.sock");
process.env.PI_DESK_PEER_CHECK = resolve(
	"tmp/candidate/Pi Desk.app/Contents/Helpers/PiDeskPeerCheck",
);
console.log(
	JSON.stringify({
		fixturePid: process.pid,
		provider: "faux-only",
		realProviderCalls: 0,
	}),
);
const hosts = [];
for (const name of ["A", "B"]) {
	const host = await createHost(root, name, { bridge: registerBridge });
	hosts.push(host);
	host.faux.setResponses(
		Array.from({ length: 32 }, () =>
			ai.fauxAssistantMessage("Synthetic native response"),
		),
	);
	await host.session.prompt("Synthetic fixture task");
}
let last = "";
const timer = setInterval(async () => {
	const state = {
		nativeSdk: true,
		realProviderCalls: 0,
		sessions: hosts.map((h) => ({
			id: h.session.sessionId,
			modelCalls: h.faux.state.callCount,
			errors: h.errors.length,
		})),
	};
	const json = JSON.stringify(state);
	if (json !== last) {
		last = json;
		await writeFile(join(root, "fixture-state.json"), json, { mode: 0o600 });
		console.log(json);
	}
}, 250);
const stop = async () => {
	clearInterval(timer);
	for (const h of hosts) await h.close();
	process.exit(0);
};
process.on("SIGUSR1", () => {
	void Promise.all(
		hosts.map((h) =>
			h.session.prompt(
				"Synthetic explicit continuation after client disappearance",
			),
		),
	);
});
process.on("SIGTERM", stop);
process.on("SIGINT", stop);
setTimeout(stop, 900000).unref();
