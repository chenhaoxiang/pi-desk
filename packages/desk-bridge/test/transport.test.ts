import test from "node:test";
import assert from "node:assert/strict";
import {
	mkdir,
	mkdtemp,
	chmod,
	rm,
	readFile,
	symlink,
	writeFile,
} from "node:fs/promises";
import { createServer } from "node:net";
import { resolve, join } from "node:path";
import { setImmediate as tick } from "node:timers/promises";
import { BridgeTransport } from "../src/transport.ts";
import { checkEndpoint } from "../src/security.ts";
import type { RecordV1 } from "../src/protocol.ts";
const fixture = JSON.parse(
	await readFile(
		new URL("../../../Fixtures/wire-v1.json", import.meta.url),
		"utf8",
	),
) as RecordV1;
const until = async (test: () => boolean) => {
	const end = Date.now() + 3000;
	while (Date.now() < end) {
		if (test()) return;
		await new Promise((r) => setTimeout(r, 5));
	}
	throw Error("fixture-timeout");
};
test("real slow socket stays bounded, overload never waits on consumer", async () => {
	await mkdir("tmp", { recursive: true });
	const dir = await mkdtemp(resolve("tmp/net-"));
	await chmod(dir, 0o700);
	const path = join(dir, "s");
	const peers = new Set<import("node:net").Socket>();
	const server = createServer((s) => {
		peers.add(s);
		s.pause();
		s.on("error", () => {});
		s.on("close", () => peers.delete(s));
	});
	await new Promise<void>((r) => server.listen(path, r));
	await chmod(path, 0o600);
	let verified = false;
	const t = new BridgeTransport(
		path,
		"fixture-only",
		() => fixture,
		() => {},
		async () => {
			verified = true;
		},
	);
	try {
		t.start();
		await until(() => verified);
		const before = process.memoryUsage().heapUsed;
		for (let i = 0; i < 1000; i++) {
			t.publish({
				...fixture,
				kind: "snapshot",
				futurePadding: "x".repeat(48000),
			} as RecordV1);
			await tick();
			assert.ok(t.queuedRecords <= 33);
		}
		assert.ok(process.memoryUsage().heapUsed - before < 32 * 1024 * 1024);
		assert.ok(t.dropped > 0 || peers.size === 0);
		assert.ok(t.queuedRecords <= 33);
	} finally {
		t.close();
		for (const peer of peers) peer.destroy();
		await new Promise<void>((r) => server.close(() => r()));
		await rm(dir, { recursive: true, force: true });
	}
});
test("endpoint rejects wrong modes, symlinks and unexpected files", async () => {
	await mkdir("tmp", { recursive: true });
	const dir = await mkdtemp(resolve("tmp/security-"));
	await chmod(dir, 0o700);
	const file = join(dir, "regular");
	await writeFile(file, "fixture", { mode: 0o600 });
	try {
		await assert.rejects(checkEndpoint(file));
		await symlink(file, join(dir, "link"));
		await assert.rejects(checkEndpoint(join(dir, "link")));
		await chmod(dir, 0o755);
		await assert.rejects(checkEndpoint(file));
		await assert.rejects(checkEndpoint("/" + "x".repeat(110)));
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
});
