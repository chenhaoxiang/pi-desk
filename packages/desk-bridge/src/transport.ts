import { createConnection, type Socket } from "node:net";
import { LineFramer, encode, type RecordV1 } from "./protocol.ts";
import { checkEndpoint, verifyPeer } from "./security.ts";
// Two lanes: a single coalesced latest snapshot, and bounded non-droppable replies.
export class BridgeTransport {
	private socket?: Socket;
	private retry?: NodeJS.Timeout;
	private heartbeat?: NodeJS.Timeout;
	private latest?: RecordV1;
	private replies: RecordV1[] = [];
	private ready = false;
	private stopped = false;
	private pumping = false;
	private delay = 100;
	dropped = 0;
	private generation = 0;
	constructor(
		readonly path: string,
		readonly helper: string,
		private hello: () => RecordV1,
		private receive: (record: RecordV1) => void,
		private timeout = verifyPeer,
	) {}
	start() {
		if (this.stopped) return;
		void this.connect();
		this.heartbeat = setInterval(() => {
			try {
				this.publish(this.hello());
			} catch {
				this.dropped++;
			}
		}, 5000);
		this.heartbeat.unref();
	}
	publish(record: RecordV1) {
		if (this.latest) this.dropped++;
		this.latest = record;
		this.schedule();
	}
	reply(record: RecordV1) {
		if (this.replies.length >= 32) {
			this.socket?.destroy();
			return;
		}
		this.replies.push(record);
		this.schedule();
	}
	private schedule() {
		if (this.pumping || this.stopped) return;
		this.pumping = true;
		setImmediate(() => {
			this.pumping = false;
			this.flush();
		}).unref();
	}
	private flush() {
		const s = this.socket;
		if (!s || !this.ready || s.destroyed) return;
		if (s.writableLength >= 131072) {
			this.dropped++;
			s.destroy();
			return;
		}
		try {
			while (this.replies.length) {
				if (!s.write(encode(this.replies.shift()!))) return;
			}
			if (this.latest) {
				const value = this.latest;
				this.latest = undefined;
				s.write(encode(value));
			}
		} catch {
			this.dropped++;
			s.destroy();
		}
	}
	private async connect() {
		const generation = ++this.generation;
		try {
			await checkEndpoint(this.path);
			if (this.stopped || generation !== this.generation) return;
			const socket = createConnection(this.path);
			this.socket = socket;
			const framer = new LineFramer();
			socket.unref();
			socket.on("error", () => {});
			socket.on("close", () => {
				if (this.socket !== socket) return;
				this.ready = false;
				this.replies = [];
				this.socket = undefined;
				this.reconnect();
			});
			socket.on("drain", () => this.schedule());
			socket.on("data", (data) => {
				if (!this.ready) return;
				try {
					for (const record of framer.append(data)) this.receive(record);
				} catch {
					socket.destroy();
				}
			});
			socket.on("connect", () => {
				socket.pause();
				void this.timeout(socket, this.helper)
					.then(() => {
						if (
							this.stopped ||
							this.socket !== socket ||
							generation !== this.generation
						) {
							socket.destroy();
							return;
						}
						this.ready = true;
						this.delay = 100;
						this.latest = undefined;
						socket.write(encode(this.hello()));
						socket.resume();
						this.schedule();
					})
					.catch(() => socket.destroy());
			});
		} catch {
			this.reconnect();
		}
	}
	private reconnect() {
		if (this.stopped || this.retry) return;
		const wait = this.delay + Math.random() * this.delay * 0.2;
		this.delay = Math.min(this.delay * 2, 5000);
		this.retry = setTimeout(() => {
			this.retry = undefined;
			void this.connect();
		}, wait);
		this.retry.unref();
	}
	close() {
		if (this.stopped) return;
		this.stopped = true;
		++this.generation;
		clearTimeout(this.retry);
		clearInterval(this.heartbeat);
		this.socket?.destroy();
		this.socket = undefined;
		this.replies = [];
		this.latest = undefined;
	}
	get queuedRecords() {
		return this.replies.length + (this.latest ? 1 : 0);
	}
}
