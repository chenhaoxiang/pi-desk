import { readFile, readdir } from "node:fs/promises";
const roots = [
	"Sources",
	"packages/desk-bridge/src",
	"Fixtures",
	".github",
	"scripts",
];
let count = 0;
async function walk(dir) {
	for (const item of await readdir(dir, { withFileTypes: true }).catch(
		() => [],
	)) {
		const p = dir + "/" + item.name;
		if (item.isDirectory()) await walk(p);
		else {
			const t = await readFile(p, "utf8");
			if (
				/(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,}|BEGIN (?:RSA |OPENSSH )?PRIVATE KEY|\/Users\/[^/\s]+\/|CANARY_RAW_SECRET_)/.test(
					t,
				) &&
				!p.endsWith("check-public.mjs")
			)
				throw Error("public-content-check: " + p);
			count++;
		}
	}
}
for (const root of roots) await walk(root);
console.log(
	"Public source check passed (" +
		count +
		" files; no credentials/models invoked).",
);
