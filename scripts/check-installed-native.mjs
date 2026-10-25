import assert from "node:assert/strict";
import {
	mkdir,
	mkdtemp,
	readFile,
	readdir,
	writeFile,
	copyFile,
	rm,
	unlink,
} from "node:fs/promises";
import { homedir } from "node:os";
import { resolve, join } from "node:path";
import { verifyLocal, sha256 } from "./local-install.ts";
import { sdk, ai, sdkRoot, until } from "./native-host.mjs";
const installed = await verifyLocal(homedir());
assert.ok(!installed.bridgePath.includes(".worktree"));
assert.ok(!installed.bridgePath.includes("/tmp/"));
const rootParent = resolve("tmp/installed-native");
await mkdir(rootParent, { recursive: true, mode: 0o700 });
const root = await mkdtemp(join(rootParent, "case-"));
// Usage recording is persistent now. Synthetic autoload checks must never enter the user's ledger.
process.env.PI_DESK_USAGE_DIR = join(root, "usage-v1");
delete process.env.PI_DESK_PEER_CHECK;
delete process.env.PI_DESK_SOCKET;
// Discovery only: no other global extension factory or account/settings store is loaded.
const resolver = new sdk.DefaultPackageManager({
	cwd: root,
	agentDir: join(homedir(), ".pi/agent"),
	settingsManager: sdk.SettingsManager.inMemory({ packages: [] }),
});
const canonical = (await resolver.resolve()).extensions.find(
	(e) => e.path === installed.entryPath,
);
assert.ok(canonical?.enabled, "canonical autodiscovery entry missing");
const sdkVersion = JSON.parse(
	await readFile(join(sdkRoot, "package.json"), "utf8"),
).version;
const hosts = [];
let stopping = false;
let serial = Promise.resolve();
async function state() {
	return {
		fixturePid: process.pid,
		installedApp: installed.appPath,
		source: installed.info.sourceCommit,
		version: installed.info.version,
		build: installed.info.build,
		bridgeDigest: installed.info.bridgeDigest,
		entrySha256: installed.entrySha256,
		helperSha256: installed.helperSha256,
		canonicalDiscovery: true,
		isolatedAutoload: true,
		usageStoreIsolated: true,
		usageRoot: process.env.PI_DESK_USAGE_DIR,
		peerHelperOverride: false,
		socketOverride: false,
		sdkVersion,
		realProviderCalls: 0,
		sessions: hosts.map((h) => ({
			id: h.session.sessionId,
			name: h.name,
			modelCalls: h.faux.state.callCount,
			errors: h.errors,
			model: h.session.model?.provider + "/" + h.session.model?.id,
			effort: h.session.thinkingLevel,
			tools: h.session.getActiveToolNames(),
		})),
	};
}
async function save() {
	await writeFile(
		join(root, "state.json"),
		JSON.stringify(await state(), null, 2),
		{ mode: 0o600 },
	);
}
async function close() {
	if (stopping) return;
	stopping = true;
	for (const h of hosts) {
		await h.session.extensionRunner.emit({
			type: "session_shutdown",
			reason: "quit",
		});
		h.session.dispose();
	}
	await save();
	process.exit(0);
}
try {
	for (const name of ["installed-A", "installed-B"]) {
		const cwd = join(root, name),
			agentDir = join(cwd, "agent");
		await mkdir(join(agentDir, "extensions"), { recursive: true, mode: 0o700 });
		const entry = join(agentDir, "extensions/pi-desk-bridge.ts");
		await copyFile(installed.entryPath, entry);
		assert.equal(sha256(await readFile(entry)), installed.entrySha256);
		const settings = sdk.SettingsManager.inMemory({
			packages: [],
			retry: { enabled: false },
			compaction: { enabled: false },
		});
		const faux = ai.fauxProvider({
			provider: "desk-" + name,
			models: [{ id: "faux" }],
			tokensPerSecond: 100000,
		});
		faux.setResponses(
			Array.from({ length: 32 }, () =>
				ai.fauxAssistantMessage("INSTALLED_NATIVE_FIXTURE_OK"),
			),
		);
		const runtime = await sdk.ModelRuntime.create({
			credentials: new ai.InMemoryCredentialStore(),
			modelsStore: new ai.InMemoryModelsStore(),
			modelsPath: null,
			refreshOnCreate: false,
			allowModelNetwork: false,
		});
		runtime.registerNativeProvider(faux.provider);
		await runtime.setRuntimeApiKey("desk-" + name, "synthetic-fixture-only");
		const loader = new sdk.DefaultResourceLoader({
			cwd,
			agentDir,
			settingsManager: settings,
			noSkills: true,
			noPromptTemplates: true,
			noThemes: true,
			noContextFiles: true,
			extensionFactories: [
				(pi) => {
					pi.on("session_start", () => pi.setSessionName(name));
				},
			],
		});
		await loader.reload();
		const loaded = loader.getExtensions();
		assert.deepEqual(loaded.errors, []);
		const extension = loaded.extensions.find((e) => e.resolvedPath === entry);
		assert.ok(extension, "implicit extension was not loaded");
		assert.equal(extension.tools.size, 0);
		assert.equal(extension.commands.size, 0);
		const errors = [];
		const { session } = await sdk.createAgentSession({
			cwd,
			agentDir,
			resourceLoader: loader,
			modelRuntime: runtime,
			model: faux.getModel(),
			thinkingLevel: "high",
			noTools: "builtin",
			settingsManager: settings,
			sessionManager: sdk.SessionManager.inMemory(cwd),
		});
		await session.bindExtensions({
			mode: "rpc",
			onError: (e) => errors.push(e.message),
		});
		assert.equal(faux.state.callCount, 0);
		hosts.push({ session, faux, errors, name });
		await session.prompt("One isolated installed bridge fixture");
	}
	if (installed.info.bridgeFiles["src/usage-store.ts"]) {
		await until(async () => {
			const spool = join(process.env.PI_DESK_USAGE_DIR, "spool");
			let count = 0;
			for (const shard of await readdir(spool).catch(() => [])) {
				if (!/^[a-f0-9]{2}$/.test(shard)) continue;
				count += (await readdir(join(spool, shard))).filter(f => /^[a-f0-9]{64}\.json$/.test(f)).length;
			}
			return count >= hosts.length;
		});
	}
	await save();
	console.log(
		JSON.stringify({
			ok: true,
			stage: "fresh-installed-autoload",
			fixtureRoot: root,
			...(await state()),
		}),
	);
	if (process.argv.includes("--serve")) {
		process.on("SIGUSR1", () => {
			serial = serial
				.then(async () => {
					for (const h of hosts)
						await h.session.prompt(
							"Explicit synthetic work while installed App is absent",
						);
					await save();
				})
				.catch((error) => {
					console.error("fixture-continuation-failed");
					process.exitCode = 1;
				});
		});
		process.on("SIGTERM", () => {
			void close();
		});
		process.on("SIGINT", () => {
			void close();
		});
		let last = "";
		const timer = setInterval(() => {
			void state().then(async (value) => {
				const body = JSON.stringify(value);
				if (body !== last) {
					last = body;
					await save();
					console.log(body);
				}
			});
		}, 250);
		setTimeout(() => {
			clearInterval(timer);
			void close();
		}, 600000);
	} else {
		for (const h of hosts) {
			await h.session.extensionRunner.emit({
				type: "session_shutdown",
				reason: "quit",
			});
			h.session.dispose();
		}
		await save();
	}
} catch (error) {
	for (const h of hosts) {
		await h.session.extensionRunner.emit({
			type: "session_shutdown",
			reason: "quit",
		});
		h.session.dispose();
	}
	throw error;
}
