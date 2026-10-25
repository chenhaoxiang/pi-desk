import { createRequire, registerHooks } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
const require = createRequire(import.meta.url);
export const sdkRoot =
	process.env.PI_DESK_SDK ??
	dirname(
		dirname(
			fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent")),
		),
	);
export const sdk = await import(
	pathToFileURL(join(sdkRoot, "dist/index.js")).href
);
export const ai = await import(
	pathToFileURL(resolve(sdkRoot, "../pi-ai/dist/index.js")).href
);
export function bindFixturePeerImports() {
	const names = new Set([
		"pi-ai",
		"pi-agent-core",
		"pi-coding-agent",
		"pi-tui",
	]);
	const hostRequire = createRequire(join(sdkRoot, "package.json"));
	const aliases = Object.fromEntries(
		["typebox", "typebox/compile", "typebox/value"].map((name) => [
			name,
			pathToFileURL(hostRequire.resolve(name)).href,
		]),
	);
	registerHooks({
		resolve(specifier, context, next) {
			if (aliases[specifier]) return next(aliases[specifier], context);
			const name = specifier.startsWith("@earendil-works/")
				? specifier.slice(16)
				: "";
			if (names.has(name))
				return next(
					pathToFileURL(resolve(sdkRoot, "../" + name + "/dist/index.js")).href,
					context,
				);
			return next(specifier, context);
		},
	});
}
export async function createHost(
	root,
	label,
	{ bridge, extensions = [], transport, tools = [], bindings = {} } = {},
) {
	const cwd = join(root, label);
	const agentDir = join(cwd, "agent");
	await mkdir(agentDir, { recursive: true, mode: 0o700 });
	await mkdir(join(cwd, ".pi"), { recursive: true, mode: 0o700 });
	await writeFile(
		join(cwd, ".pi/settings.json"),
		JSON.stringify({
			packages: [],
			subagents: { projectRootResolution: "nearest" },
		}),
		{ mode: 0o600 },
	);
	const faux = ai.fauxProvider({
		provider: "desk-fixture-" + label,
		models: [{ id: "faux" }],
		tokensPerSecond: 100000,
	});
	const runtime = await sdk.ModelRuntime.create({
		credentials: new ai.InMemoryCredentialStore(),
		modelsStore: new ai.InMemoryModelsStore(),
		modelsPath: null,
		refreshOnCreate: false,
		allowModelNetwork: false,
	});
	runtime.registerNativeProvider(faux.provider);
	await runtime.setRuntimeApiKey(
		"desk-fixture-" + label,
		"synthetic-fixture-only",
	);
	const settings = sdk.SettingsManager.inMemory({
		packages: [],
		retry: { enabled: false },
		compaction: { enabled: false },
	});
	let api;
	const errors = [];
	const factories = [
		(pi) => {
			api = pi;
			pi.on("session_start", () => pi.setSessionName("合成 Pi " + label));
		},
		...extensions,
	];
	if (bridge)
		factories.push((pi) => bridge(pi, { ...(transport ? { transport } : {}), usageRoot: join(root, "usage-v1") }));
	const loader = new sdk.DefaultResourceLoader({
		cwd,
		agentDir,
		settingsManager: settings,
		noExtensions: true,
		noSkills: true,
		noPromptTemplates: true,
		noThemes: true,
		noContextFiles: true,
		extensionFactories: factories,
	});
	await loader.reload();
	const { session } = await sdk.createAgentSession({
		cwd,
		agentDir,
		modelRuntime: runtime,
		model: faux.getModel(),
		thinkingLevel: "high",
		noTools: "builtin",
		customTools: tools,
		settingsManager: settings,
		sessionManager: sdk.SessionManager.inMemory(cwd),
		resourceLoader: loader,
	});
	await session.bindExtensions({
		mode: "rpc",
		...bindings,
		onError: (e) => errors.push(e.message),
	});
	return {
		session,
		faux,
		api,
		services: { cwd, agentDir, modelRuntime: runtime, settingsManager: settings, resourceLoader: loader, diagnostics: [] },
		errors,
		close: async () => {
			await session.extensionRunner.emit({
				type: "session_shutdown",
				reason: "quit",
			});
			session.dispose();
		},
	};
}
export async function until(predicate, ms = 6000) {
	const end = Date.now() + ms;
	while (Date.now() < end) {
		if (await predicate()) return;
		await new Promise((r) => setTimeout(r, 15));
	}
	throw Error("fixture-condition-timeout");
}
