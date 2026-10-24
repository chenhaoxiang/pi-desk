import test from "node:test";
import assert from "node:assert/strict";
import {
	mkdir,
	mkdtemp,
	writeFile,
	readFile,
	lstat,
	readdir,
	rm,
	symlink,
	chmod,
	cp,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import {
	installLocal,
	verifyLocal,
	rollbackLocal,
	sha256,
	BUNDLE_ID,
} from "../../../scripts/local-install.ts";
const signatureFixture = () => {};
async function fakeBundle(root: string, letter: string) {
	const app = join(root, "source-" + letter + ".app");
	const bridge = join(app, "Contents/Resources/bridge");
	await mkdir(join(bridge, "src"), { recursive: true, mode: 0o700 });
	await mkdir(join(app, "Contents/MacOS"), { recursive: true });
	await mkdir(join(app, "Contents/Helpers"));
	const files = {
		"package.json": JSON.stringify({ name: "pi-desk-bridge", private: true }),
		"src/index.ts": "export default function fixture(){}",
	};
	const hashes: Record<string, string> = {};
	for (const [path, value] of Object.entries(files)) {
		await writeFile(join(bridge, path), value);
		hashes[path] = sha256(value);
	}
	await writeFile(join(app, "Contents/MacOS/PiDesk"), "fixture-app-" + letter, {
		mode: 0o755,
	});
	await writeFile(
		join(app, "Contents/Helpers/PiDeskPeerCheck"),
		"fixture-helper",
		{ mode: 0o755 },
	);
	await writeFile(join(app, "Contents/Info.plist"), "synthetic-plist");
	const info = {
		schema: 1,
		product: "pi-desk",
		bundleId: BUNDLE_ID,
		version: "0.1.0",
		build: "1",
		channel: "local",
		configuration: "release",
		sourceCommit: letter.repeat(40),
		sourceTree: "c".repeat(40),
		sourceState: "clean",
		bridgeDigest: sha256(JSON.stringify(hashes)),
		bridgeFiles: hashes,
	};
	await writeFile(
		join(app, "Contents/Resources/BuildInfo.json"),
		JSON.stringify(info),
	);
	return app;
}
async function fixture() {
	await mkdir("tmp", { recursive: true });
	const root = await mkdtemp(resolve("tmp/install-"));
	const home = join(root, "home");
	await mkdir(home, { mode: 0o700 });
	return {
		root,
		home,
		cleanup: async () => {
			async function writable(path: string) {
				const s = await lstat(path);
				if (s.isSymbolicLink() || !s.isDirectory()) return;
				await chmod(path, 0o700);
				for (const name of await readdir(path))
					await writable(join(path, name));
			}
			await writable(root);
			await rm(root, { recursive: true, force: true });
		},
	};
}
test("stable installation pins bridge bytes, preserves settings, idempotent and rolls back", async () => {
	const f = await fixture();
	try {
		const app = await fakeBundle(f.root, "a");
		await mkdir(join(f.home, ".pi/agent"), { recursive: true });
		const settings = join(f.home, ".pi/agent/settings.json");
		await writeFile(
			settings,
			JSON.stringify({
				defaultModel: "fixture/model",
				defaultThinkingLevel: "high",
				packages: ["fixture-existing"],
			}),
			{ mode: 0o600 },
		);
		const before = sha256(await readFile(settings));
		const installed = await installLocal(f.home, app, signatureFixture);
		assert.equal(installed.appPath, join(f.home, "Applications/Pi Desk.app"));
		assert.ok(!installed.bridgePath.includes("source-a.app"));
		assert.equal(installed.info.sourceCommit, "a".repeat(40));
		assert.equal(sha256(await readFile(settings)), before);
		assert.equal(
			(await lstat(join(installed.bridgePath, "src/index.ts"))).mode & 0o222,
			0,
		);
		const entry = await readFile(installed.entryPath, "utf8");
		assert.ok(entry.includes(installed.bridgePath));
		assert.ok(entry.includes("sourceRevision"));
		assert.ok(!entry.includes("--extension"));
		assert.deepEqual(
			await installLocal(f.home, app, signatureFixture),
			installed,
		);
		assert.deepEqual(await verifyLocal(f.home, signatureFixture), installed);
		assert.equal(await rollbackLocal(f.home, signatureFixture), null);
		await assert.rejects(lstat(installed.appPath));
		await assert.rejects(lstat(installed.entryPath));
		assert.equal(sha256(await readFile(settings)), before);
	} finally {
		await f.cleanup();
	}
});
test("an update keeps exact previous App and entry for rollback", async () => {
	const f = await fixture();
	try {
		const a = await fakeBundle(f.root, "a"),
			b = await fakeBundle(f.root, "b");
		const first = await installLocal(f.home, a, signatureFixture);
		const second = await installLocal(f.home, b, signatureFixture);
		assert.notEqual(first.appDigest, second.appDigest);
		const restored = await rollbackLocal(f.home, signatureFixture);
		assert.equal(restored?.appDigest, first.appDigest);
		assert.equal(
			(await verifyLocal(f.home, signatureFixture)).entrySha256,
			first.entrySha256,
		);
	} finally {
		await f.cleanup();
	}
});
test("unmanaged or modified destination is preserved, never silently replaced", async () => {
	const f = await fixture();
	try {
		const app = await fakeBundle(f.root, "a");
		const target = join(f.home, "Applications/Pi Desk.app");
		await mkdir(target, { recursive: true });
		await writeFile(join(target, "unrelated"), "preserve");
		await assert.rejects(
			installLocal(f.home, app, signatureFixture),
			/unmanaged/,
		);
		assert.equal(await readFile(join(target, "unrelated"), "utf8"), "preserve");
		await rm(target, { recursive: true });
		const first = await installLocal(f.home, app, signatureFixture);
		await writeFile(first.entryPath, "unknown user edit");
		await assert.rejects(
			installLocal(f.home, app, signatureFixture),
			/modified/,
		);
		assert.equal(await readFile(first.entryPath, "utf8"), "unknown user edit");
	} finally {
		await f.cleanup();
	}
});
test("dirty/mismatched source, symlink and active installation lock fail narrowly", async () => {
	const f = await fixture();
	try {
		const app = await fakeBundle(f.root, "a");
		const path = join(app, "Contents/Resources/BuildInfo.json");
		const original = JSON.parse(await readFile(path, "utf8"));
		await writeFile(
			path,
			JSON.stringify({ ...original, sourceState: "dirty" }),
		);
		await assert.rejects(
			installLocal(f.home, app, signatureFixture),
			/unfrozen/,
		);
		await writeFile(path, JSON.stringify(original));
		await writeFile(
			join(app, "Contents/Resources/bridge/src/index.ts"),
			"tampered",
		);
		await assert.rejects(
			installLocal(f.home, app, signatureFixture),
			/byte-mismatch/,
		);
		const support = join(f.home, "Library/Application Support/PiDesk");
		await writeFile(join(support, ".install.lock"), "owned-fixture-lock", {
			mode: 0o600,
		});
		await assert.rejects(installLocal(f.home, app, signatureFixture), /EEXIST/);
		assert.equal(
			await readFile(join(support, ".install.lock"), "utf8"),
			"owned-fixture-lock",
		);
		await rm(join(support, ".install.lock"));
		const otherHome = join(f.root, "linked-home");
		await symlink(f.home, otherHome);
		await assert.rejects(
			installLocal(otherHome, app, signatureFixture),
			/symlink|unsafe/,
		);
	} finally {
		await f.cleanup();
	}
});
test("post-install verification failure restores the previous managed installation", async () => {
	const f = await fixture();
	try {
		const a = await fakeBundle(f.root, "a"),
			b = await fakeBundle(f.root, "b");
		const first = await installLocal(f.home, a, signatureFixture);
		await assert.rejects(
			installLocal(f.home, b, async (path) => {
				if (path === first.appPath) {
					const info = JSON.parse(
						await readFile(
							join(path, "Contents/Resources/BuildInfo.json"),
							"utf8",
						),
					);
					if (info.sourceCommit === "b".repeat(40))
						throw Error("synthetic-signature-failure");
				}
			}),
			/synthetic-signature/,
		);
		assert.deepEqual(await verifyLocal(f.home, signatureFixture), first);
	} finally {
		await f.cleanup();
	}
});
