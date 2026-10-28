import { createHash, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { constants } from "node:fs";
import {
	lstat,
	mkdir,
	readFile,
	writeFile,
	readdir,
	cp,
	copyFile,
	chmod,
	rename,
	unlink,
	rm,
	open,
} from "node:fs/promises";
import { join, dirname, resolve, relative } from "node:path";

export const BUNDLE_ID = "io.github.chenhaoxiang.pi-desk";
const ENTRY_NAME = "pi-desk-bridge.ts";
export const sha256 = (bytes: string | Buffer) =>
	createHash("sha256").update(bytes).digest("hex");
type BuildInfo = {
	schema: 1;
	product: "pi-desk";
	bundleId: string;
	version: string;
	build: string;
	channel: string;
	configuration: string;
	sourceCommit: string;
	sourceTree: string;
	sourceState: string;
	bridgeDigest: string;
	bridgeFiles: Record<string, string>;
};
type RecordInfo = {
	schema: 1;
	product: "pi-desk";
	info: BuildInfo;
	appPath: string;
	bridgePath: string;
	entryPath: string;
	appDigest: string;
	appSha256: string;
	helperSha256: string;
	entrySha256: string;
	previousBackup: string | null;
	installedAt: string;
};
type Paths = {
	home: string;
	app: string;
	support: string;
	entry: string;
	record: string;
};
type SignatureCheck = (path: string) => void | Promise<void>;
const codesign: SignatureCheck = (path) => {
	execFileSync("/usr/bin/codesign", ["--verify", "--strict", "--deep", path], {
		stdio: "pipe",
	});
};
const exists = async (path: string) =>
	lstat(path).then(
		() => true,
		(error) => {
			if (error.code === "ENOENT") return false;
			throw error;
		},
	);
function paths(home: string): Paths {
	if (!home.startsWith("/") || resolve(home) !== home)
		throw Error("invalid-home");
	return {
		home,
		app: join(home, "Applications/Pi Desk.app"),
		support: join(home, "Library/Application Support/PiDesk"),
		entry: join(home, ".pi/agent/extensions", ENTRY_NAME),
		record: join(
			home,
			"Library/Application Support/PiDesk/install-current.json",
		),
	};
}
async function directory(path: string, privateLeaf = false) {
	const parent = dirname(path);
	if (parent !== path) await directoryExists(parent);
	if (!(await exists(path))) await mkdir(path, { mode: 0o700 });
	const s = await lstat(path);
	if (
		!s.isDirectory() ||
		s.isSymbolicLink() ||
		s.uid !== process.getuid?.() ||
		(s.mode & 0o022) !== 0 ||
		(privateLeaf && (s.mode & 0o077) !== 0)
	)
		throw Error("unsafe-install-directory");
}
async function directoryExists(path: string): Promise<void> {
	if (path === "/") return;
	const parent = dirname(path);
	await directoryExists(parent);
	if (!(await exists(path))) {
		await mkdir(path, { mode: 0o700 });
		return;
	}
	const s = await lstat(path);
	if (!s.isDirectory() || s.isSymbolicLink())
		throw Error("symlink-install-ancestor");
}
async function regular(path: string, max = 1048576) {
	const s = await lstat(path);
	if (
		!s.isFile() ||
		s.isSymbolicLink() ||
		s.nlink !== 1 ||
		s.size > max ||
		![0, process.getuid?.()].includes(s.uid) ||
		(s.mode & 0o022) !== 0
	)
		throw Error("unsafe-install-file");
	return readFile(path);
}
async function json<T>(path: string): Promise<T> {
	return JSON.parse((await regular(path)).toString("utf8")) as T;
}
async function atomic(path: string, bytes: string | Buffer) {
	const temp = join(dirname(path), ".pi-desk-" + randomUUID() + ".tmp");
	try {
		await writeFile(temp, bytes, { flag: "wx", mode: 0o600 });
		await rename(temp, path);
	} finally {
		await unlink(temp).catch((error) => {
			if (error.code !== "ENOENT") throw error;
		});
	}
}
export async function treeDigest(root: string): Promise<string> {
	const rows: string[] = [];
	let count = 0;
	async function walk(dir: string) {
		const s = await lstat(dir);
		if (!s.isDirectory() || s.isSymbolicLink())
			throw Error("unsafe-app-directory");
		for (const name of (await readdir(dir)).sort()) {
			const path = join(dir, name);
			const stat = await lstat(path);
			if (stat.isSymbolicLink()) throw Error("symlink-in-install-payload");
			if (stat.isDirectory()) await walk(path);
			else {
				if (++count > 512) throw Error("install-file-count");
				const bytes = await regular(path, 20 * 1024 * 1024);
				rows.push(
					relative(root, path) +
						":" +
						(stat.mode & 0o777) +
						":" +
						sha256(bytes),
				);
			}
		}
	}
	await walk(root);
	return sha256(rows.join("\n"));
}
async function bridgeCheck(root: string, info: BuildInfo) {
	const expected = Object.keys(info.bridgeFiles).sort();
	if (
		!expected.length ||
		expected.length > 64 ||
		!expected.includes("src/index.ts")
	)
		throw Error("invalid-bridge-inventory");
	const actual: string[] = [];
	async function walk(dir: string) {
		const rootStat = await lstat(dir);
		if (!rootStat.isDirectory() || rootStat.isSymbolicLink())
			throw Error("unsafe-bridge-directory");
		for (const name of (await readdir(dir)).sort()) {
			if (actual.length > 64) throw Error("bridge-file-count");
			const path = join(dir, name);
			const s = await lstat(path);
			if (s.isSymbolicLink()) throw Error("symlink-in-bridge");
			if (s.isDirectory()) await walk(path);
			else actual.push(relative(root, path));
		}
	}
	await walk(root);
	if (JSON.stringify(actual.sort()) !== JSON.stringify(expected))
		throw Error("bridge-file-set-mismatch");
	const verified: Record<string, string> = {};
	for (const file of expected) {
		if (
			!/^(src\/[A-Za-z0-9._-]+\.ts|package\.json)$/.test(file) ||
			!/^[a-f0-9]{64}$/.test(info.bridgeFiles[file])
		)
			throw Error("invalid-bridge-file");
		verified[file] = sha256(await regular(join(root, file), 262144));
		if (verified[file] !== info.bridgeFiles[file])
			throw Error("bridge-byte-mismatch");
	}
	if (sha256(JSON.stringify(verified)) !== info.bridgeDigest)
		throw Error("bridge-digest-mismatch");
}
export async function inspectBundle(
	app: string,
	verifySignature: SignatureCheck = codesign,
) {
	await treeDigest(app);
	await verifySignature(app);
	const info = await json<BuildInfo>(
		join(app, "Contents/Resources/BuildInfo.json"),
	);
	if (
		info.schema !== 1 ||
		info.product !== "pi-desk" ||
		info.bundleId !== BUNDLE_ID ||
		info.configuration !== "release" ||
		info.sourceState !== "clean" ||
		!/^\d+\.\d+\.\d+$/.test(info.version) ||
		!/^\d+$/.test(info.build) ||
		!/^[a-f0-9]{40}$/.test(info.sourceCommit) ||
		!/^[a-f0-9]{40}$/.test(info.sourceTree) ||
		!/^[a-f0-9]{64}$/.test(info.bridgeDigest)
	)
		throw Error("unfrozen-or-invalid-bundle");
	await bridgeCheck(join(app, "Contents/Resources/bridge"), info);
	return {
		info,
		appDigest: await treeDigest(app),
		appSha256: sha256(
			await regular(join(app, "Contents/MacOS/PiDesk"), 20 * 1024 * 1024),
		),
		helperSha256: sha256(
			await regular(join(app, "Contents/Helpers/PiDeskPeerCheck"), 1048576),
		),
	};
}
function entryText(bridgePath: string, source: string) {
	return (
		"// Pi Desk managed autodiscovery entry; source " +
		source +
		'.\nimport type {ExtensionAPI} from "@earendil-works/pi-coding-agent";\nimport {registerBridge} from ' +
		JSON.stringify(join(bridgePath, "src/index.ts")) +
		";\nexport const piDeskInstalledSource=" +
		JSON.stringify(source) +
		";\nexport default function(pi:ExtensionAPI):void{registerBridge(pi,{sourceRevision:piDeskInstalledSource});}\n"
	);
}
async function managed(
	p: Paths,
	verifySignature: SignatureCheck,
): Promise<RecordInfo | null> {
	const hasRecord = await exists(p.record),
		hasApp = await exists(p.app),
		hasEntry = await exists(p.entry);
	if (!hasRecord) {
		if (hasApp || hasEntry) throw Error("unmanaged-install-preserved");
		return null;
	}
	if (!hasApp || !hasEntry) throw Error("incomplete-install-preserved");
	const record = await json<RecordInfo>(p.record);
	if (
		record.schema !== 1 ||
		record.product !== "pi-desk" ||
		record.appPath !== p.app ||
		record.entryPath !== p.entry ||
		record.bridgePath !== join(p.support, "bridge", record.info.sourceCommit)
	)
		throw Error("invalid-install-record");
	const actual = await inspectBundle(p.app, verifySignature);
	if (
		actual.appDigest !== record.appDigest ||
		actual.info.sourceCommit !== record.info.sourceCommit ||
		sha256(await regular(p.entry)) !== record.entrySha256 ||
		sha256(entryText(record.bridgePath, record.info.sourceCommit)) !==
			record.entrySha256
	)
		throw Error("modified-install-preserved");
	await bridgeCheck(record.bridgePath, record.info);
	return record;
}
export async function verifyLocal(
	home: string,
	verifySignature: SignatureCheck = codesign,
) {
	const p = paths(home);
	const record = await managed(p, verifySignature);
	if (!record) throw Error("not-installed");
	return record;
}
export async function installLocal(
	home: string,
	source: string,
	verifySignature: SignatureCheck = codesign,
) {
	const p = paths(home);
	await directory(p.home);
	await directory(dirname(p.app));
	await directory(p.support, true);
	await directory(dirname(p.entry));
	const lockPath = join(p.support, ".install.lock");
	const lock = await open(
		lockPath,
		constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
		0o600,
	);
	let stage: string | undefined;
	let backupApp: string | undefined;
	let previous: RecordInfo | null = null;
	let entryChanged = false,
		appChanged = false,
		recordChanged = false;
	const tx = randomUUID();
	const backup = join(p.support, "backups", tx);
	try {
		previous = await managed(p, verifySignature);
		const candidate = await inspectBundle(source, verifySignature);
		const bridgePath = join(p.support, "bridge", candidate.info.sourceCommit);
		await directory(dirname(bridgePath), true);
		if (await exists(bridgePath)) await bridgeCheck(bridgePath, candidate.info);
		else {
			await cp(join(source, "Contents/Resources/bridge"), bridgePath, {
				recursive: true,
				errorOnExist: true,
				force: false,
			});
			await bridgeCheck(bridgePath, candidate.info);
			for (const file of Object.keys(candidate.info.bridgeFiles))
				await chmod(join(bridgePath, file), 0o444);
			await chmod(join(bridgePath, "src"), 0o555);
			await chmod(bridgePath, 0o555);
		}
		const entry = entryText(bridgePath, candidate.info.sourceCommit);
		if (
			previous &&
			previous.appDigest === candidate.appDigest &&
			previous.entrySha256 === sha256(entry)
		)
			return previous;
		stage = join(dirname(p.app), ".pi-desk-stage-" + tx + ".app");
		await cp(source, stage, {
			recursive: true,
			errorOnExist: true,
			force: false,
		});
		if (
			(await inspectBundle(stage, verifySignature)).appDigest !==
			candidate.appDigest
		)
			throw Error("staged-app-mismatch");
		await directory(join(p.support, "backups"), true);
		await directory(backup, true);
		await writeFile(
			join(backup, "previous.json"),
			JSON.stringify(previous, null, 2) + "\n",
			{ mode: 0o600, flag: "wx" },
		);
		if (previous) {
			await copyFile(p.entry, join(backup, "entry.ts"));
			await chmod(join(backup, "entry.ts"), 0o600);
			backupApp = join(dirname(p.app), ".pi-desk-backup-" + tx + ".app");
			await rename(p.app, backupApp);
			await writeFile(
				join(backup, "app-path.json"),
				JSON.stringify(backupApp),
				{ mode: 0o600, flag: "wx" },
			);
		}
		if (!previous && (await exists(p.app)))
			throw Error("app-destination-appeared-preserved");
		await rename(stage, p.app);
		stage = undefined;
		appChanged = true;
		if (previous) {
			if (sha256(await regular(p.entry)) !== previous.entrySha256)
				throw Error("entry-changed-preserved");
		} else if (await exists(p.entry))
			throw Error("entry-destination-appeared-preserved");
		await atomic(p.entry, entry);
		entryChanged = true;
		const record: RecordInfo = {
			schema: 1,
			product: "pi-desk",
			info: candidate.info,
			appPath: p.app,
			bridgePath,
			entryPath: p.entry,
			appDigest: candidate.appDigest,
			appSha256: candidate.appSha256,
			helperSha256: candidate.helperSha256,
			entrySha256: sha256(entry),
			previousBackup: backup,
			installedAt: new Date().toISOString(),
		};
		await atomic(p.record, JSON.stringify(record, null, 2) + "\n");
		recordChanged = true;
		return await verifyLocal(home, verifySignature);
	} catch (error) {
		if (entryChanged) {
			if (previous)
				await atomic(p.entry, await regular(join(backup, "entry.ts")));
			else await unlink(p.entry);
		}
		if (appChanged) await rm(p.app, { recursive: true });
		if (backupApp && (await exists(backupApp))) await rename(backupApp, p.app);
		if (recordChanged) {
			if (previous)
				await atomic(p.record, JSON.stringify(previous, null, 2) + "\n");
			else if (await exists(p.record)) await unlink(p.record);
		}
		throw error;
	} finally {
		if (stage) await rm(stage, { recursive: true, force: true });
		await lock.close();
		await unlink(lockPath);
	}
}
export async function rollbackLocal(
	home: string,
	verifySignature: SignatureCheck = codesign,
) {
	const p = paths(home);
	const lockPath = join(p.support, ".install.lock");
	const lock = await open(
		lockPath,
		constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY,
		0o600,
	);
	let current: RecordInfo | null = null,
		previous: RecordInfo | null = null,
		previousApp: string | undefined;
	let movedCurrent = false,
		movedPrevious = false,
		changedEntry = false,
		changedRecord = false;
	const held = join(
		dirname(p.app),
		".pi-desk-rollback-" + randomUUID() + ".app",
	);
	try {
		current = await managed(p, verifySignature);
		if (!current) throw Error("not-installed");
		const backup = current.previousBackup;
		if (!backup || dirname(backup) !== join(p.support, "backups"))
			throw Error("invalid-rollback-backup");
		previous = await json<RecordInfo | null>(join(backup, "previous.json"));
		if (previous) {
			if (
				previous.schema !== 1 ||
				previous.product !== "pi-desk" ||
				previous.appPath !== p.app ||
				previous.entryPath !== p.entry ||
				previous.bridgePath !==
					join(p.support, "bridge", previous.info.sourceCommit)
			)
				throw Error("invalid-previous-install-record");
			previousApp = await json<string>(join(backup, "app-path.json"));
			if (
				dirname(previousApp) !== dirname(p.app) ||
				!previousApp.includes(".pi-desk-backup-")
			)
				throw Error("invalid-rollback-app");
			if (
				(await inspectBundle(previousApp, verifySignature)).appDigest !==
					previous.appDigest ||
				sha256(await regular(join(backup, "entry.ts"))) !== previous.entrySha256
			)
				throw Error("rollback-byte-mismatch");
			await bridgeCheck(previous.bridgePath, previous.info);
		}
		await rename(p.app, held);
		movedCurrent = true;
		if (previous && previousApp) {
			await rename(previousApp, p.app);
			movedPrevious = true;
			await atomic(p.entry, await regular(join(backup, "entry.ts")));
			changedEntry = true;
			await atomic(p.record, JSON.stringify(previous, null, 2) + "\n");
			changedRecord = true;
			await verifyLocal(home, verifySignature);
		} else {
			await unlink(p.entry);
			changedEntry = true;
			await unlink(p.record);
			changedRecord = true;
		}
		await rm(held, { recursive: true });
		return previous;
	} catch (error) {
		if (current) {
			if (movedPrevious && previousApp) await rename(p.app, previousApp);
			if (movedCurrent && (await exists(held))) await rename(held, p.app);
			if (changedEntry)
				await atomic(
					p.entry,
					entryText(current.bridgePath, current.info.sourceCommit),
				);
			if (changedRecord)
				await atomic(p.record, JSON.stringify(current, null, 2) + "\n");
		}
		throw error;
	} finally {
		await lock.close();
		await unlink(lockPath);
	}
}
