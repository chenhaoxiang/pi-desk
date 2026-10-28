import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
const out = "tmp/visual-preview/Pi Desk Preview.app";
await mkdir("tmp/visual-preview", { recursive: true });
await cp("tmp/candidate/Pi Desk.app", out, { recursive: true, force: true });
const p = out + "/Contents/Resources/BuildInfo.json",
	info = JSON.parse(await readFile(p, "utf8"));
info.bundleId = "io.github.chenhaoxiang.pi-desk.visual-preview";
info.channel = "visual-preview";
await writeFile(p, JSON.stringify(info));
execFileSync("/usr/bin/plutil", [
	"-replace",
	"CFBundleIdentifier",
	"-string",
	info.bundleId,
	out + "/Contents/Info.plist",
]);
execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", out]);
console.log(out);
