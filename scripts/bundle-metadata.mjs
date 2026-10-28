import { readFile, writeFile, mkdir, lstat, copyFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { resolve, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const app = resolve(process.argv[2] ?? "");
if (!app.startsWith(join(root, "tmp") + "/"))
	throw Error("bundle-must-be-local-output");
const git = (...args) =>
	execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const sha = (data) => createHash("sha256").update(data).digest("hex");
const sourceCommit = git("rev-parse", "HEAD"),
	sourceTree = git("rev-parse", "HEAD^{tree}");
const sourceState =
	git("status", "--porcelain", "--untracked-files=normal") === ""
		? "clean"
		: "dirty";
const files = git(
	"ls-files",
	"--",
	"packages/desk-bridge/src",
	"packages/desk-bridge/package.json",
)
	.split("\n")
	.filter(Boolean)
	.sort();
const inventory = {};
const bridgeRoot = join(app, "Contents/Resources/bridge");
for (const file of files) {
	const relative = file.slice("packages/desk-bridge/".length);
	if (!/^(src\/[A-Za-z0-9._-]+\.ts|package\.json)$/.test(relative))
		throw Error("unexpected-bridge-file");
	const source = join(root, file);
	const stat = await lstat(source);
	if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 262144)
		throw Error("invalid-bridge-source");
	const bytes = await readFile(source);
	inventory[relative] = sha(bytes);
	await mkdir(dirname(join(bridgeRoot, relative)), { recursive: true });
	await copyFile(source, join(bridgeRoot, relative));
}
if (!inventory["src/index.ts"]) throw Error("missing-bridge-entry");
const info = {
	schema: 1,
	product: "pi-desk",
	bundleId: "io.github.chenhaoxiang.pi-desk",
	version: "0.1.0",
	build: git("rev-list", "--count", "HEAD"),
	channel: "local",
	configuration: process.argv[3] ?? "release",
	sourceCommit,
	sourceTree,
	sourceState,
	bridgeDigest: sha(JSON.stringify(inventory)),
	bridgeFiles: inventory,
};
await writeFile(
	join(app, "Contents/Resources/BuildInfo.json"),
	JSON.stringify(info, null, 2) + "\n",
);
for (const [key, value] of Object.entries({
	CFBundleIdentifier: info.bundleId,
	CFBundleVersion: info.build,
	PiDeskBuildChannel: info.channel,
	PiDeskSourceRevision: sourceCommit,
	PiDeskSourceTree: sourceTree,
	PiDeskSourceState: sourceState,
	PiDeskBridgeDigest: info.bridgeDigest,
}))
	execFileSync("/usr/bin/plutil", [
		"-replace",
		key,
		"-string",
		value,
		join(app, "Contents/Info.plist"),
	]);
console.log(
	JSON.stringify({
		bundle: info.bundleId,
		version: info.version,
		build: info.build,
		sourceCommit,
		sourceState,
		bridgeDigest: info.bridgeDigest,
	}),
);
