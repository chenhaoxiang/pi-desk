#!/usr/bin/env python3
"""Explicit one-shot Pi usage metadata import. Never print or persist session text.

Only canonical Pi session JSONL (or an isolated repo tmp fixture) is admitted.
The independent low-priority worker streams frozen prefixes into a private stage
SQLite. Runtime Pi and original JSONL files are never modified.
"""
from __future__ import annotations
import argparse, collections, datetime as dt, hashlib, json, math, os, resource, shutil
import socket, sqlite3, stat, sys, time, uuid
from pathlib import Path

FIELDS = ("input", "output", "cacheRead", "cacheWrite")
MIN_TIME = 946684800000
MAX_LINE = 16 * 1024 * 1024
SCHEMA = "pi-history-metadata-v1"
ROOT = Path(__file__).resolve().parents[1]
CANONICAL = Path.home() / ".pi/agent/sessions"
SUPPORT = Path.home() / "Library/Application Support/PiDesk"
BACKUPS = Path.home() / "Library/Application Support/PiDesk History Backups"


def digest(value):
    return hashlib.sha256(value.encode("utf8") if isinstance(value, str) else value).hexdigest()


def private_dir(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise ValueError("unsafe-private-directory")


def private_json(path, value):
    path = Path(path)
    private_dir(path.parent)
    temporary = path.with_name(".receipt-" + uuid.uuid4().hex)
    with os.fdopen(os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as out:
        json.dump(value, out, ensure_ascii=False, sort_keys=True, indent=2)
        out.flush(); os.fsync(out.fileno())
    os.replace(temporary, path)


def safe_id(value):
    return isinstance(value, str) and 0 < len(value) <= 128 and all(c.isascii() and (c.isalnum() or c in "._-") for c in value)


def occurrence(value):
    if isinstance(value, bool): return None
    if isinstance(value, (int, float)) and (isinstance(value, int) or math.isfinite(value)) and value == int(value):
        n = int(value)
    elif isinstance(value, str):
        try:
            date = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if date.tzinfo is None: return None
            n = int(date.timestamp() * 1000)
        except (ValueError, OverflowError): return None
    else: return None
    return n if MIN_TIME <= n <= int(time.time() * 1000) else None


def clean_tokens(value):
    result, reasons = [], []
    if not isinstance(value, dict): return [None] * 4, ["missing-usage"]
    for key in FIELDS:
        n = value.get(key)
        if isinstance(n, (int, float)) and not isinstance(n, bool) and (isinstance(n, int) or math.isfinite(n)) and n == int(n) and 0 <= n <= 9007199254740991:
            result.append(int(n))
        else:
            result.append(None); reasons.append("missing-or-invalid-" + key)
    return result, reasons


def physical_model(provider, model):
    allowed = "._:/+@ -"
    if isinstance(provider, str) and isinstance(model, str):
        value = provider + "/" + model
        if len(value) <= 128 and all(c.isascii() and (c.isalnum() or c in allowed) for c in value): return value
    return "unknown"


def regular(path, writable=False):
    flags = os.O_RDWR if writable else os.O_RDONLY
    fd = os.open(path, flags | os.O_NOFOLLOW)
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
        os.close(fd); raise ValueError("unsafe-file")
    return fd, s


def file_hash(path, limit=None):
    h = hashlib.sha256(); fd, s = regular(path)
    try:
        with os.fdopen(fd, "rb", buffering=262144) as source:
            remaining = s.st_size if limit is None else limit
            while remaining:
                chunk = source.read(min(262144, remaining))
                if not chunk: raise ValueError("source-prefix-shortened")
                h.update(chunk); remaining -= len(chunk)
        return h.hexdigest()
    except Exception:
        raise


def discover(root):
    root = Path(root)
    if not root.is_dir() or root.is_symlink(): raise ValueError("unsafe-session-root")
    paths = {}
    for base, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(name for name in dirs if not Path(base, name).is_symlink())
        for name in sorted(files):
            p = Path(base, name)
            if name.endswith(".jsonl") and not p.is_symlink() and p.is_file():
                paths[digest(str(p.relative_to(root)))] = p
    return paths


def stage_schema(db):
    db.executescript("""
      PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-16384;
      CREATE TABLE files(key TEXT PRIMARY KEY,dev INTEGER,ino INTEGER,size INTEGER,mtime INTEGER,header_hash TEXT,session_hash TEXT,parent_key TEXT,has_parent INTEGER,header_time INTEGER,prefix_hash TEXT,status TEXT);
      CREATE TABLE raw(file_key TEXT,entry_key TEXT,live_id TEXT,session TEXT,occurred INTEGER,model TEXT,input INTEGER,output INTEGER,cache_read INTEGER,cache_write INTEGER,kind TEXT,fingerprint TEXT,reasons TEXT,status TEXT,PRIMARY KEY(file_key,entry_key));
      CREATE TABLE normalized(id TEXT PRIMARY KEY,session TEXT,occurred INTEGER,model TEXT,input INTEGER,output INTEGER,cache_read INTEGER,cache_write INTEGER,kind TEXT,fingerprint TEXT,reasons TEXT,status TEXT);
      CREATE TABLE aliases(alias_id TEXT PRIMARY KEY,canonical_id TEXT,fingerprint TEXT,kind TEXT);
      CREATE TABLE counters(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
    """)


def freeze_headers(paths, db, root):
    host_id = digest(socket.gethostname() + ":" + str(os.getuid()))[:32]
    header_info = {}
    for key, path in sorted(paths.items()):
        fd, s = regular(path)
        with os.fdopen(fd, "rb") as f: line = f.readline(262145)
        try: obj = json.loads(line) if len(line) <= 262144 else None
        except Exception: obj = None
        valid = isinstance(obj, dict) and obj.get("type") == "session" and safe_id(obj.get("id")) and obj.get("version", 1) in (1, 2, 3)
        sid = obj["id"] if valid else None
        parent_key, has_parent = None, 0
        if valid and isinstance(obj.get("parentSession"), str):
            has_parent = 1
            parent = Path(obj["parentSession"])
            if not parent.is_absolute(): parent = path.parent / parent
            try: parent_key = digest(str(parent.resolve().relative_to(root.resolve())))
            except ValueError: parent_key = None
        sh = digest(host_id + ":" + sid) if sid else None
        ht = occurrence(obj.get("timestamp")) if valid else None
        header_info[key] = (sid, sh)
        db.execute("INSERT INTO files VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (key,s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,digest(sid) if sid else None,sh,parent_key,has_parent,ht,None,"frozen" if valid else "not-pi-header"))
    db.commit()
    return header_info


def project(obj, sid, session_hash, counters):
    if not isinstance(obj, dict): return None
    kind = obj.get("type")
    if kind not in ("message", "usage", "compaction", "branch_summary"): return None
    if kind == "message":
        msg = obj.get("message")
        if not isinstance(msg, dict) or msg.get("role") != "assistant": return None
        if msg.get("stopReason") in ("pending", "deferred"):
            counters["not-final"] += 1; return None
        usage = msg.get("usage")
        model = physical_model(msg.get("provider"), msg.get("model"))
        when = occurrence(msg.get("timestamp")) or occurrence(obj.get("timestamp"))
        source_kind = "assistant"
    else:
        usage = obj.get("usage")
        model = physical_model(obj.get("provider"), obj.get("model"))
        when = occurrence(obj.get("timestamp"))
        source_kind = kind
    if not isinstance(usage, dict): counters["usage-not-provided"] += 1; return None
    if not safe_id(obj.get("id")): counters["missing-stable-entry-id"] += 1; return None
    if when is None: counters["missing-valid-occurrence"] += 1; return None
    tok, reasons = clean_tokens(usage)
    if model == "unknown": reasons.append("model-not-provided")
    if kind in ("compaction", "branch_summary") and model == "unknown": counters["summary-model-unknown"] += 1
    # Four normalized non-overlapping buckets only: reasoning/cacheWrite1h are subsets.
    fingerprint = digest("|".join([source_kind,str(when),model] + ["null" if n is None else str(n) for n in tok]))
    live_id = digest(session_hash + ":" + obj["id"])
    return (digest(obj["id"]),live_id,session_hash,when,model,*tok,source_kind,fingerprint,json.dumps(sorted(set(reasons))),"eligible")


def scan_file(key, path, row, ids, db, counters, throttle):
    fd, initial = regular(path)
    if initial.st_dev != row["dev"] or initial.st_ino != row["ino"] or initial.st_size < row["size"]:
        os.close(fd); raise ValueError("source-changed-before-scan")
    remaining, carry, dropping = row["size"], bytearray(), False
    h = hashlib.sha256(); paced = 0
    def line(raw, final=False):
        if not raw.strip(): return
        try: obj = json.loads(raw)
        except Exception:
            counters["incomplete-tail" if final else "malformed-lines"] += 1; return
        projected = project(obj, ids[key][0], ids[key][1], counters)
        if projected:
            old = db.execute("SELECT fingerprint FROM raw WHERE file_key=? AND entry_key=?",(key,projected[0])).fetchone()
            if old:
                if old[0] == projected[-3]: counters["same-file-replay"] += 1
                else:
                    db.execute("UPDATE raw SET status='conflict' WHERE file_key=? AND entry_key=?",(key,projected[0]));counters["same-entry-conflict"] += 1
            else: db.execute("INSERT INTO raw VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",(key,*projected))
        del obj
    with os.fdopen(fd,"rb",buffering=262144) as source:
        while remaining:
            chunk = source.read(min(262144,remaining))
            if not chunk: raise ValueError("source-prefix-shortened")
            h.update(chunk);remaining -= len(chunk);counters["bytes-scanned"] += len(chunk);paced += len(chunk)
            pieces = chunk.split(b"\n")
            for i, piece in enumerate(pieces):
                if not dropping:
                    if len(carry)+len(piece) > MAX_LINE:
                        dropping=True;carry.clear();counters["oversized-lines"] += 1
                    else: carry.extend(piece)
                if i < len(pieces)-1:
                    if not dropping: line(carry)
                    carry.clear();dropping=False
            if paced >= 2*1024*1024:
                time.sleep(throttle);paced=0
        if carry and not dropping: line(carry, True)
        after = os.fstat(source.fileno())
    if after.st_size > row["size"]: counters["files-appended-after-freeze"] += 1
    db.execute("UPDATE files SET prefix_hash=?,status='scanned' WHERE key=?",(h.hexdigest(),key))
    db.commit()


def normalize(db, counters):
    files = {r["key"]:dict(r) for r in db.execute("SELECT * FROM files")}
    @__import__('functools').lru_cache(maxsize=16384)
    def resolve(key, entry_key):
        current = db.execute("SELECT * FROM raw WHERE file_key=? AND entry_key=?",(key,entry_key)).fetchone()
        if not current or current["status"] != "eligible": return None
        cur = files[key]; seen={key}; parent=cur["parent_key"]
        while parent:
            if parent in seen: counters["parent-cycle"] += 1;return None
            seen.add(parent)
            if parent not in files or files[parent]["status"] != "scanned" or (files[parent]["has_parent"] and not files[parent]["parent_key"]):
                counters["unresolved-parent-chain"] += 1;return None
            old = db.execute("SELECT * FROM raw WHERE file_key=? AND entry_key=?",(parent,entry_key)).fetchone()
            if old:
                if old["fingerprint"] != current["fingerprint"] or old["status"] != "eligible": counters["parent-entry-collision"] += 1;return None
                current=old;cur=files[parent]
            parent=files[parent]["parent_key"]
        if cur["has_parent"] and not cur["parent_key"]:
            counters["unresolved-parent-chain"] += 1;return None
        if cur["has_parent"] and (cur["header_time"] is None or current["occurred"] < cur["header_time"]):
            counters["unresolved-inherited-entry"] += 1;return None
        return current
    for row in db.execute("SELECT * FROM raw ORDER BY file_key,entry_key"):
        canonical = resolve(row["file_key"],row["entry_key"])
        if canonical is None: counters["ambiguous-candidates"] += 1;continue
        old = db.execute("SELECT fingerprint FROM normalized WHERE id=?",(canonical["live_id"],)).fetchone()
        values = (canonical["live_id"],canonical["session"],canonical["occurred"],canonical["model"],canonical["input"],canonical["output"],canonical["cache_read"],canonical["cache_write"],canonical["kind"],canonical["fingerprint"],canonical["reasons"],"eligible")
        if old and old[0] != canonical["fingerprint"]:
            db.execute("UPDATE normalized SET status='conflict' WHERE id=?",(canonical["live_id"],));counters["canonical-conflict"] += 1
        else: db.execute("INSERT OR IGNORE INTO normalized VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",values)
        if row["live_id"] != canonical["live_id"]:
            db.execute("INSERT OR IGNORE INTO aliases VALUES(?,?,?,?)",(row["live_id"],canonical["live_id"],canonical["fingerprint"],canonical["kind"]));counters["fork-copy-aliases"] += 1
    db.commit()


def summarize(db, live=None):
    totals=[0]*4; added=[0]*4; missing=[0]*4; kinds=collections.Counter();models={};reasons=collections.Counter();dates=[]; matched=conflicts=eligible=new_records=0
    for r in db.execute("SELECT * FROM normalized"):
        if r["status"] != "eligible": conflicts += 1;continue
        eligible += 1;dates.append(r["occurred"]);kinds[r["kind"]] += 1
        values=[r[k] for k in ("input","output","cache_read","cache_write")]
        for i,n in enumerate(values):
            if n is None: missing[i] += 1
            else: totals[i] += n
        reasons.update(json.loads(r["reasons"]))
        old=live.execute("SELECT session,occurred,model,input,output,cache_read,cache_write FROM usage_entries WHERE id=?",(r["id"],)).fetchone() if live else None
        same=old and tuple(old)==tuple(r[k] for k in ("session","occurred","model","input","output","cache_read","cache_write"))
        if old:
            if same: matched += 1
            else: conflicts += 1
        else:
            new_records += 1
            m=models.setdefault(r["model"],{"records":0,"tokens":[0]*4});m["records"] += 1
            for i,n in enumerate(values):
                if n is not None: added[i] += n;m["tokens"][i] += n
    return {"eligibleUniqueRecords":eligible,"matchedExisting":matched,"estimatedNew":new_records,"conflicts":conflicts,"candidateKnownTokens":dict(zip(FIELDS,totals)),"estimatedNewKnownTokens":dict(zip(FIELDS,added)),"missingFields":dict(zip(FIELDS,missing)),"kinds":dict(kinds),"models":models,"minUTCms":min(dates) if dates else None,"maxUTCms":max(dates) if dates else None,"coverageReasons":dict(reasons)}


def preview(sessions, run, live_path, throttle=0.002):
    private_dir(run);start=time.monotonic();paths=discover(sessions)
    db=sqlite3.connect(run/"stage.sqlite3");os.chmod(run/"stage.sqlite3",0o600);db.row_factory=sqlite3.Row;stage_schema(db)
    ids=freeze_headers(paths,db,sessions);counters=collections.Counter();files=list(db.execute("SELECT * FROM files ORDER BY key"));total=sum(r["size"] for r in files)
    for index,row in enumerate(files):
        if row["status"] != "frozen": counters["non-pi-or-unsupported-header"] += 1;continue
        scan_file(row["key"],paths[row["key"]],row,ids,db,counters,throttle)
        if index%50==0: private_json(run/"progress.json",{"phase":"metadata-preview","filesDone":index+1,"filesTotal":len(files),"bytesScanned":counters["bytes-scanned"],"bytesTotal":total,"seconds":time.monotonic()-start})
    normalize(db,counters)
    source_manifest=[dict(r) for r in db.execute("SELECT * FROM files ORDER BY key")]
    source_hash=digest(json.dumps(source_manifest,sort_keys=True,separators=(",",":")))
    import_id=uuid.uuid4().hex
    live=sqlite3.connect(Path(live_path).as_uri()+"?mode=ro",uri=True) if Path(live_path).exists() else None
    if live: live.execute("BEGIN")
    summary=summarize(db,live)
    if live: live.rollback();live.close()
    for key,value in counters.items():db.execute("INSERT OR REPLACE INTO counters VALUES(?,?)",(key,value))
    db.commit();db.close()
    private_json(run/"source-manifest.json",{"schema":SCHEMA,"rootHash":digest(str(sessions)),"files":source_manifest,"sourceSetHash":source_hash})
    elapsed=time.monotonic()-start;rss=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*(1 if sys.platform=="darwin" else 1024)
    result={"schema":SCHEMA,"importId":import_id,"sourceSetHash":source_hash,"sourceRootHash":digest(str(sessions)),"manifestSHA256":file_hash(run/"source-manifest.json"),"stageSHA256":file_hash(run/"stage.sqlite3"),"createdUTC":dt.datetime.now(dt.timezone.utc).isoformat(),"files":len(files),"sourceBytes":total,"scannedBytes":counters["bytes-scanned"],"seconds":elapsed,"bytesPerSecond":counters["bytes-scanned"]/max(elapsed,.001),"peakRSSBytes":rss,"counters":dict(counters),"summary":summary,"contentStored":False,"applyAutomatically":False}
    private_json(run/"preview.json",result);return result


def import_schema(db):
    # Additive tables only: old live table stays exactly eight columns, so build16 remains usable.
    db.execute("CREATE TABLE IF NOT EXISTS usage_provenance(id TEXT PRIMARY KEY,origin TEXT NOT NULL,import_id TEXT NOT NULL,kind TEXT NOT NULL,coverage TEXT NOT NULL,has_realtime INTEGER NOT NULL DEFAULT 0)")
    db.execute("CREATE TABLE IF NOT EXISTS history_imports(import_id TEXT PRIMARY KEY,source_set_hash TEXT NOT NULL,applied INTEGER NOT NULL,status TEXT NOT NULL,summary_json TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS usage_aliases(alias_id TEXT PRIMARY KEY,canonical_id TEXT NOT NULL,fingerprint TEXT NOT NULL,kind TEXT NOT NULL,import_id TEXT NOT NULL)")
    db.execute("CREATE TABLE IF NOT EXISTS history_conflicts(id TEXT NOT NULL,import_id TEXT NOT NULL,reason TEXT NOT NULL,PRIMARY KEY(id,import_id))")


def backup_consistent(path, manifest, backup_dir):
    private_dir(backup_dir);snapshot=backup_dir/"usage-snapshot.sqlite3"
    read=sqlite3.connect(Path(path).as_uri()+"?mode=ro",uri=True);dest=sqlite3.connect(snapshot);read.backup(dest,pages=256,sleep=.005);dest.close();read.close();os.chmod(snapshot,0o600)
    files=[]
    for name,source in [("usage.sqlite3",Path(path)),("usage.sqlite3-wal",Path(str(path)+"-wal")),("usage.sqlite3-shm",Path(str(path)+"-shm")),("install-current.json",Path(manifest))]:
        if source.exists():
            target=backup_dir/("raw-"+name);shutil.copyfile(source,target);os.chmod(target,0o600);files.append({"file":target.name,"present":True,"sha256":file_hash(target)})
        else:files.append({"file":"raw-"+name,"present":False})
    receipt={"method":"SQLite backup API includes committed WAL","snapshotSHA256":file_hash(snapshot),"files":files,"createdUTC":dt.datetime.now(dt.timezone.utc).isoformat()}
    private_json(backup_dir/"backup-receipt.json",receipt);return receipt


def verify_sources(sessions, manifest):
    paths=discover(sessions);verified=appended=0
    for row in manifest["files"]:
        if row["status"] != "scanned":continue
        path=paths.get(row["key"])
        if not path: raise ValueError("source-file-missing")
        fd,s=regular(path);os.close(fd)
        if s.st_dev!=row["dev"] or s.st_ino!=row["ino"] or s.st_size<row["size"]:raise ValueError("source-identity-or-prefix-changed")
        if s.st_size!=row["size"] or s.st_mtime_ns!=row["mtime"]:
            if file_hash(path,row["size"])!=row["prefix_hash"]:raise ValueError("source-prefix-changed")
            if s.st_size>row["size"]:appended+=1
        verified+=1
    return {"verifiedFrozenPrefixes":verified,"filesAppendedBeyondSnapshot":appended,"newFilesAfterPreview":max(0,len(paths)-len(manifest["files"]))}


def checked_usage_db(path):
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(path) + suffix)
        if suffix and not candidate.exists() and not candidate.is_symlink(): continue
        fd, checked = regular(candidate); os.close(fd)
        if checked.st_nlink != 1 or checked.st_mode & 0o077: raise ValueError("unsafe-usage-database")
    db = sqlite3.connect(path, timeout=5); db.execute("PRAGMA busy_timeout=5000"); db.row_factory = sqlite3.Row
    if db.execute("PRAGMA application_id").fetchone()[0] != 1346978901 or db.execute("PRAGMA user_version").fetchone()[0] != 1:
        db.close(); raise ValueError("not-pi-desk-usage-database")
    return db


def apply(run,sessions,db_path,install_manifest,backup_root=BACKUPS,fail_after=None):
    p=json.loads((run/"preview.json").read_text());manifest=json.loads((run/"source-manifest.json").read_text());import_id=p["importId"]
    if p["schema"]!=SCHEMA or p["sourceRootHash"]!=digest(str(sessions)) or p["manifestSHA256"]!=file_hash(run/"source-manifest.json") or p["stageSHA256"]!=file_hash(run/"stage.sqlite3"):raise ValueError("preview-integrity-failed")
    db = checked_usage_db(db_path)
    if db.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='history_imports'").fetchone()[0]:
        old=db.execute("SELECT summary_json,status FROM history_imports WHERE import_id=?",(import_id,)).fetchone()
        if old and old["status"]=="applied": result=json.loads(old[0]);result["repeatedApplyNoChange"]=True;db.close();return result
    verified=verify_sources(sessions,manifest)
    if db.execute("PRAGMA quick_check(1)").fetchone()[0]!="ok":raise ValueError("existing-database-not-healthy")
    db.execute("BEGIN IMMEDIATE")
    private_dir(backup_root)
    backup_dir=Path(backup_root)/import_id
    receipt=backup_consistent(db_path,install_manifest,backup_dir)
    stage=sqlite3.connect((run/"stage.sqlite3").as_uri()+"?mode=ro",uri=True);stage.row_factory=sqlite3.Row
    inserted=matched=conflicts=aliases=0;added=[0]*4;models={};kinds=collections.Counter()
    try:
        import_schema(db)
        for r in stage.execute("SELECT * FROM normalized WHERE status='eligible' ORDER BY id"):
            values=tuple(r[k] for k in ("session","occurred","model","input","output","cache_read","cache_write"))
            old=db.execute("SELECT session,occurred,model,input,output,cache_read,cache_write FROM usage_entries WHERE id=?",(r["id"],)).fetchone()
            if old:
                if tuple(old)==values:matched+=1
                else:
                    db.execute("INSERT OR IGNORE INTO usage_conflicts VALUES(?)",(r["id"],));db.execute("INSERT OR IGNORE INTO history_conflicts VALUES(?,?,?)",(r["id"],import_id,"same-consumption-key-content-conflict"));conflicts+=1
                continue
            db.execute("INSERT INTO usage_entries(id,session,occurred,model,input,output,cache_read,cache_write) VALUES(?,?,?,?,?,?,?,?)",(r["id"],*values))
            db.execute("INSERT INTO usage_provenance VALUES(?,?,?,?,?,0)",(r["id"],"history",import_id,r["kind"],r["reasons"]))
            inserted+=1;kinds[r["kind"]]+=1;m=models.setdefault(r["model"],{"records":0,"tokens":[0]*4});m["records"]+=1
            for i,n in enumerate(values[3:]):
                if n is not None:added[i]+=n;m["tokens"][i]+=n
            if fail_after is not None and inserted>=fail_after:raise ValueError("synthetic-apply-failure")
        for a in stage.execute("SELECT * FROM aliases"):
            canonical=db.execute("SELECT session,occurred,model,input,output,cache_read,cache_write FROM usage_entries WHERE id=?",(a["canonical_id"],)).fetchone()
            if not canonical: continue
            alias=db.execute("SELECT session,occurred,model,input,output,cache_read,cache_write FROM usage_entries WHERE id=?",(a["alias_id"],)).fetchone()
            if alias:
                # An already-recorded child copy cannot simply be deleted. Suppress
                # only its proven identical consumption alias in the combined view.
                if tuple(alias)[1:] != tuple(canonical)[1:]:
                    db.execute("INSERT OR IGNORE INTO history_conflicts VALUES(?,?,?)",(a["alias_id"],import_id,"fork-alias-content-conflict"));conflicts+=1;continue
            db.execute("INSERT OR IGNORE INTO usage_aliases VALUES(?,?,?,?,?)",(a["alias_id"],a["canonical_id"],a["fingerprint"],a["kind"],import_id));aliases+=1
        result={"schema":SCHEMA,"importId":import_id,"sourceSetHash":p["sourceSetHash"],"sourceFiles":p["files"],"scannedBytes":p["scannedBytes"],"candidates":p["summary"]["eligibleUniqueRecords"],"inserted":inserted,"matchedExisting":matched,"conflicts":conflicts,"aliases":aliases,"importedKnownTokens":dict(zip(FIELDS,added)),"models":models,"kinds":dict(kinds),"minUTCms":p["summary"]["minUTCms"],"maxUTCms":p["summary"]["maxUTCms"],"coverage":p["counters"],"missingFields":p["summary"]["missingFields"],"backupKey":import_id,"backupSHA256":receipt["snapshotSHA256"],"status":"applied",**verified}
        db.execute("INSERT INTO history_imports VALUES(?,?,?,?,?)",(import_id,p["sourceSetHash"],int(time.time()*1000),"applied",json.dumps(result,separators=(",",":"))))
        if db.execute("PRAGMA quick_check(1)").fetchone()[0]!="ok":raise ValueError("post-import-check-failed")
        db.commit();private_json(backup_dir/"apply-receipt.json",result);private_json(run/"apply-receipt.json",result);return result
    except Exception:
        db.rollback();private_json(backup_dir/"failed-apply.json",{"importId":import_id,"status":"rolled-back","reason":"apply-transaction-failed","sourceSetHash":p["sourceSetHash"]});raise
    finally:stage.close();db.close()


def rollback(import_id,db_path,backup_root=BACKUPS):
    db=checked_usage_db(db_path);db.execute("BEGIN IMMEDIATE")
    try:
        row=db.execute("SELECT status FROM history_imports WHERE import_id=?",(import_id,)).fetchone()
        if not row:raise ValueError("unknown-import")
        if row["status"]=="rolled-back":db.rollback();return {"importId":import_id,"status":"rolled-back","repeatedRollbackNoChange":True}
        removable=[r[0] for r in db.execute("SELECT id FROM usage_provenance WHERE import_id=? AND has_realtime=0",(import_id,))]
        for key in removable:db.execute("DELETE FROM usage_entries WHERE id=?",(key,))
        db.execute("DELETE FROM usage_provenance WHERE import_id=?",(import_id,))
        # Identity aliases whose canonical consumption survives (pre-existing or
        # later realtime-confirmed) must survive too, or a subsequent live replay
        # could charge the copied entry a second time after rollback.
        db.execute("DELETE FROM usage_aliases WHERE import_id=? AND NOT EXISTS(SELECT 1 FROM usage_entries e WHERE e.id=usage_aliases.canonical_id)",(import_id,))
        # Existing conflict facts are audit evidence; rollback never clears a
        # pre-existing/live conflict flag merely to make the display green.
        db.execute("UPDATE history_imports SET status='rolled-back' WHERE import_id=?",(import_id,));db.commit()
        result={"importId":import_id,"status":"rolled-back","removedImportedOnlyRows":len(removable),"newRealtimePreserved":True};private_json(Path(backup_root)/import_id/"rollback-receipt.json",result);return result
    except Exception:db.rollback();raise
    finally:db.close()


def main():
    os.umask(0o077)
    ap=argparse.ArgumentParser();ap.add_argument("mode",choices=["preview","apply","rollback"]);ap.add_argument("--sessions",type=Path,default=CANONICAL);ap.add_argument("--run",type=Path);ap.add_argument("--db",type=Path,default=SUPPORT/"usage-v1/usage.sqlite3");ap.add_argument("--install-manifest",type=Path,default=SUPPORT/"install-current.json");ap.add_argument("--import-id");args=ap.parse_args()
    os.nice(10)
    sessions=args.sessions.absolute()
    if sessions!=CANONICAL.absolute() and not str(sessions).startswith(str(ROOT/"tmp")+os.sep):raise ValueError("source-scope-not-authorized")
    if args.mode=="rollback":result=rollback(args.import_id,args.db)
    elif args.mode=="preview":
        run=args.run or ROOT/"tmp/history-backfill"/("run-"+uuid.uuid4().hex)
        result=preview(sessions,run,args.db)
    else:
        if not args.run:raise ValueError("preview-run-required")
        result=apply(args.run,sessions,args.db,args.install_manifest)
    print(json.dumps(result,ensure_ascii=False,separators=(",",":")))

if __name__=="__main__":
    try:main()
    except Exception as error:
        # Never echo JSON objects, source text, exceptions containing paths or raw parse errors.
        print(json.dumps({"ok":False,"errorType":type(error).__name__,"reason":str(error) if isinstance(error,ValueError) and str(error).replace('-','').isalnum() else "metadata-operation-failed"}),file=sys.stderr)
        sys.exit(1)
