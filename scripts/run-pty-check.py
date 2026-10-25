#!/usr/bin/env python3
"""Run only the owned synthetic native TUI check inside a bounded local PTY."""
import errno
import json
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import fcntl
import time

root = pathlib.Path(__file__).resolve().parents[1]
run = pathlib.Path(tempfile.mkdtemp(prefix="pty-", dir=root / "tmp"))
result = run / "result.json"
env = os.environ.copy()
env.update({"PI_CODING_AGENT_DIR": str(run / "agent"), "PI_OFFLINE": "1", "PI_DESK_TUI_RESULT": str(result), "TERM": "xterm-256color"})
(run / "agent").mkdir(mode=0o700)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
soak = "--soak" in sys.argv
performance = "--performance" in sys.argv
args = ["node", "--import", "tsx", "scripts/check-lifecycle-soak.mjs", "--tui"] if soak else (["node", "--import", "tsx", "scripts/check-owner-performance.mjs", "--tui"] if performance else ["node", "--import", "tsx", "scripts/check-interactive-pty.mjs"])
limit = 960 if soak else 90 if performance else 45
child = subprocess.Popen(args, cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
start, received = time.monotonic(), 0
try:
    while child.poll() is None and time.monotonic() - start < limit:
        ready, _, _ = select.select([master], [], [], .25)
        if ready:
            try:
                data = os.read(master, 65536)
                received += len(data)
                # Reply to terminal capabilities/cursor queries only; no app consent or business input.
                if b"\x1b[6n" in data:
                    os.write(master, b"\x1b[1;1R")
                if b"\x1b[c" in data or b"\x1b[0c" in data:
                    os.write(master, b"\x1b[?1;2c")
            except OSError as e:
                if e.errno != errno.EIO: raise
                break
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        try: child.wait(timeout=2)
        except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL)
    value = json.loads(result.read_text()) if result.exists() else {"ok": False, "error": "PTY child produced no result"}
    value.update({"ptyOutputBytes": received, "exitCode": child.wait(), "run": str(run)})
    (run / "wrapper-result.json").write_text(json.dumps(value, indent=2))
    print(json.dumps(value))
    sys.exit(0 if value["ok"] and value["exitCode"] == 0 else 1)
finally:
    os.close(master)
