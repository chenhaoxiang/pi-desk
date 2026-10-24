import { lstat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import type { Socket } from "node:net";
export function runtimePath() {
	return (
		process.env.PI_DESK_SOCKET ??
		join(homedir(), "Library/Caches/PiDesk/runtime/desk.sock")
	);
}
export function helperPath() {
	return (
		process.env.PI_DESK_PEER_CHECK ??
		join(homedir(), "Applications/Pi Desk.app/Contents/Helpers/PiDeskPeerCheck")
	);
}
export async function checkEndpoint(path: string) {
	if (!path.startsWith("/") || Buffer.byteLength(path) > 103)
		throw Error("invalid-socket-path");
	// Every existing ancestor must be a directory, never a symlink.
	let parent = dirname(path);
	const dir = await lstat(parent);
	if (
		!dir.isDirectory() ||
		dir.isSymbolicLink() ||
		dir.uid !== process.getuid?.() ||
		(dir.mode & 0o077) !== 0
	)
		throw Error("unsafe-runtime-directory");
	while (parent !== "/") {
		const s = await lstat(parent);
		if (!s.isDirectory() || s.isSymbolicLink()) throw Error("unsafe-ancestor");
		parent = dirname(parent);
	}
	const socket = await lstat(path);
	if (
		!socket.isSocket() ||
		socket.isSymbolicLink() ||
		socket.uid !== process.getuid?.() ||
		(socket.mode & 0o077) !== 0
	)
		throw Error("unsafe-socket");
}
export async function verifyPeer(socket: Socket, path: string): Promise<void> {
	if (!path.startsWith("/") || resolve(path) !== path)
		throw Error("invalid-peer-helper");
	const s = await lstat(path);
	if (
		!s.isFile() ||
		s.isSymbolicLink() ||
		![0, process.getuid?.()].includes(s.uid) ||
		(s.mode & 0o022) !== 0
	)
		throw Error("unsafe-peer-helper");
	await new Promise<void>((resolve, reject) => {
		const child = spawn(path, [], {
			stdio: ["ignore", "pipe", "ignore", socket],
		});
		let output = "";
		let done = false;
		let exited = false;
		let stdoutEnded = false;
		let exitCode: number | null = null;
		const complete = () => {
			if (exited && stdoutEnded)
				finish(exitCode === 0 && output.trim() === String(process.getuid?.()));
		};
		const finish = (ok: boolean) => {
			if (done) return;
			done = true;
			clearTimeout(timeout);
			ok ? resolve() : reject(Error("peer-uid-mismatch"));
		};
		const timeout = setTimeout(() => {
			child.kill();
			finish(false);
		}, 1000);
		timeout.unref();
		child.stdout!.on("data", (b) => {
			output += String(b);
			if (output.length > 32) {
				child.kill();
				finish(false);
			}
		});
		child.on("error", () => finish(false));
		// ChildProcess close also waits for the parent-owned socket passed as fd 3.
		// Join exit with stdout EOF instead; never wait for that live socket.
		child.stdout!.on("end", () => {
			stdoutEnded = true;
			complete();
		});
		child.on("exit", (code) => {
			exited = true;
			exitCode = code;
			complete();
		});
	});
}
