import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, copyFile, rm, lstat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL("../../../", import.meta.url));
const commands = [
	["install:local", "install", /Pi Desk local installation: ENOENT/],
	["verify:local", "verify", /Pi Desk local installation: not-installed/],
	["rollback:local", "rollback", /Pi Desk local installation: not-installed/],
] as const;

for (const [script, command, expectedError] of commands) {
	test(`${script} reaches the real installer without node_modules or a preloader`, async () => {
		await mkdir(resolve(source, "tmp"), { recursive: true });
		const root = await mkdtemp(resolve(source, "tmp/install-cli-"));
		const project = join(root, "project"), home = join(root, "home");
		try {
			await mkdir(join(project, "scripts"), { recursive: true, mode: 0o700 });
			await mkdir(join(home, "Library/Application Support/PiDesk"), { recursive: true, mode: 0o700 });
			for (const file of ["install-local.mjs", "local-install.ts"]) {
				await copyFile(join(source, "scripts", file), join(project, "scripts", file));
			}
			await copyFile(join(source, "package.json"), join(project, "package.json"));
			const manifest = JSON.parse(await readFile(join(project, "package.json"), "utf8"));
			const [runtime, ...args] = manifest.scripts[script].split(" ");
			assert.equal(runtime, "node");
			// A surrounding checkout may have devDependencies. Do not let ancestor
			// module resolution hide a reintroduced tsx/other preload requirement.
			assert.deepEqual(args, ["scripts/install-local.mjs", command]);
			await assert.rejects(lstat(join(project, "node_modules")), { code: "ENOENT" });
			const before = (await readdir(home, { recursive: true })).sort();
			const result = spawnSync(process.execPath, args, {
				cwd: project,
				env: { ...process.env, HOME: home, NODE_OPTIONS: "", NODE_PATH: "" },
				encoding: "utf8", timeout: 10000,
			});
			assert.ifError(result.error);
			assert.equal(result.signal, null);
			assert.equal(result.status, 1);
			assert.equal(result.stdout, "");
			assert.match(result.stderr, expectedError);
			assert.doesNotMatch(result.stderr, /ERR_MODULE_NOT_FOUND|ERR_UNKNOWN_FILE_EXTENSION/);
			for (const path of [
				join(home, "Applications/Pi Desk.app"),
				join(home, ".pi/agent/extensions/pi-desk-bridge.ts"),
				join(home, "Library/Application Support/PiDesk/install-current.json"),
				join(home, "Library/Application Support/PiDesk/.install.lock"),
			]) await assert.rejects(lstat(path), { code: "ENOENT" });
			if (command !== "install") assert.deepEqual((await readdir(home, { recursive: true })).sort(), before);
		} finally {
			await rm(root, { recursive: true, force: true });
		}
	});
}
