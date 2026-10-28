#!/usr/bin/env python3
"""Read-only macOS process counters for a bounded, explicitly selected Pi Desk PID.

No conversation/source files, credentials, sampling profiler, or UI mutations.
CPU is cumulative process CPU time (not top's instantaneous percentage). Disk
counters are physical I/O reported by proc_pid_rusage; cached reads may be zero.
"""
import argparse
import ctypes
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import time

class RusageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idleWakeups", "interruptWakeups", "pageins", "wired", "rss", "footprint",
        "start", "exit", "childUser", "childSystem", "childIdle", "childInterrupt", "childPageins", "childElapsed",
        "readBytes", "writeBytes")]

lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
lib.proc_pid_rusage.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_void_p)
lib.proc_pid_rusage.restype = ctypes.c_int

def sample(pid):
    r = RusageV2()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(r)) != 0:
        raise RuntimeError("process-counters-unavailable")
    return {name: int(getattr(r, name)) for name in ("user", "system", "idleWakeups", "interruptWakeups", "pageins", "rss", "footprint", "start", "readBytes", "writeBytes")}

def ledger_metadata(path):
    # Fixed scalar query only; this connection never imports spool or writes DB.
    c = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
    try:
        c.execute("PRAGMA query_only=ON")
        count, maximum = c.execute("SELECT count(*),COALESCE(max(rowid),0) FROM usage_entries").fetchone()
        return {"records": count, "maxRowid": maximum}
    finally:
        c.close()

def main():
    os.umask(0o077)
    ap = argparse.ArgumentParser()
    ap.add_argument("--pid", type=int, required=True)
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--scope", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--usage-root", type=Path, default=Path.home() / "Library/Application Support/PiDesk/usage-v1")
    args = ap.parse_args()
    if not 30 <= args.seconds <= 60:
        raise ValueError("profile-window-must-be-30-to-60-seconds")
    args.out.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    before_db = ledger_metadata(args.usage_root / "usage.sqlite3")
    start = time.monotonic()
    samples = [sample(args.pid)]
    deadline = start + args.seconds
    while time.monotonic() < deadline:
        time.sleep(min(1, max(0, deadline - time.monotonic())))
        samples.append(sample(args.pid))
    elapsed = time.monotonic() - start
    after_db = ledger_metadata(args.usage_root / "usage.sqlite3")
    first, last = samples[0], samples[-1]
    if any(s["start"] != first["start"] for s in samples):
        raise RuntimeError("pid-replaced-during-profile")
    cpu_ns = last["user"] + last["system"] - first["user"] - first["system"]
    result = {
        "schema": 1, "scope": args.scope, "pid": args.pid,
        "finishedUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "seconds": elapsed, "cpuSeconds": cpu_ns / 1e9,
        "averageOneCoreCPUPercent": cpu_ns / 1e9 / elapsed * 100,
        "rssStartBytes": first["rss"], "rssEndBytes": last["rss"], "rssPeakSampleBytes": max(s["rss"] for s in samples),
        "diskReadBytes": last["readBytes"] - first["readBytes"], "diskWriteBytes": last["writeBytes"] - first["writeBytes"],
        "pageins": last["pageins"] - first["pageins"], "idleWakeups": last["idleWakeups"] - first["idleWakeups"],
        "ledgerBefore": before_db, "ledgerAfter": after_db,
        "ledgerRowDelta": after_db["maxRowid"] - before_db["maxRowid"],
        "inputChanged": before_db != after_db,
        "method": "proc_pid_rusage(RUSAGE_INFO_V2); cumulative CPU nanoseconds and physical disk I/O; read-only scalar DB count/max-rowid",
        "limitations": "live Pi arrivals and rendering affect samples; cached disk reads may not appear; this is not a zero-overhead or general benchmark claim",
    }
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    os.chmod(args.out, 0o600)
    print(json.dumps(result))

if __name__ == "__main__":
    main()
