import { spawn } from "node:child_process";
// Fixed read-only Git metadata only. Never runs on an observation handler.
async function git(cwd: string, args: string[]): Promise<string | undefined> {
	return new Promise((resolve) => {
		const child = spawn("/usr/bin/git", ["-C", cwd, ...args], {
			stdio: ["ignore", "pipe", "ignore"],
			env: {
				PATH: "/usr/bin:/bin",
				HOME: process.env.HOME,
				GIT_OPTIONAL_LOCKS: "0",
				GIT_TERMINAL_PROMPT: "0",
			},
		});
		let output = "";
		let done = false;
		const finish = (value?: string) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			resolve(value);
		};
		const timer = setTimeout(() => {
			child.kill();
			finish();
		}, 1500);
		timer.unref();
		child.stdout.on("data", (data) => {
			output += String(data);
			if (Buffer.byteLength(output) > 1024) {
				child.kill();
				finish();
			}
		});
		child.on("error", () => finish());
		child.on("exit", (code) => finish(code === 0 ? output.trim() : undefined));
	});
}
export async function projectMetadata(cwd: string) {
	const [branch, worktree] = await Promise.all([
		git(cwd, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
		git(cwd, ["rev-parse", "--show-toplevel"]),
	]);
	return { branch, worktree };
}
