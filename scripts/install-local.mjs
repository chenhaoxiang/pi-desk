import { homedir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { installLocal, verifyLocal, rollbackLocal } from "./local-install.ts";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const command = process.argv[2] ?? "verify";
try {
	let record;
	if (command === "install") {
		record = await installLocal(
			homedir(),
			resolve(root, "tmp/candidate/Pi Desk.app"),
		);
	} else if (command === "verify") record = await verifyLocal(homedir());
	else if (command === "rollback") record = await rollbackLocal(homedir());
	else throw Error("use-install-verify-or-rollback");
	console.log(
		JSON.stringify({ command, installed: record !== null, record }, null, 2),
	);
} catch (error) {
	console.error(
		"Pi Desk local installation: " +
			(error instanceof Error ? error.message : "failed"),
	);
	process.exitCode = 1;
}
