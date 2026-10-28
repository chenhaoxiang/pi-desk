#!/usr/bin/env python3
import importlib.util,sys,sqlite3,json,datetime as dt,hashlib,socket,os,tempfile,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode=True
os.umask(0o077)
spec=importlib.util.spec_from_file_location('history_backfill',ROOT/'scripts/history-backfill.py');m=importlib.util.module_from_spec(spec);sys.modules[spec.name]=m;spec.loader.exec_module(m)

def init_db(path):
 c=sqlite3.connect(path);c.executescript('PRAGMA journal_mode=WAL;PRAGMA user_version=1;PRAGMA application_id=1346978901;CREATE TABLE usage_entries(id TEXT PRIMARY KEY,session TEXT,occurred INTEGER,model TEXT,input INTEGER,output INTEGER,cache_read INTEGER,cache_write INTEGER);CREATE TABLE usage_conflicts(id TEXT PRIMARY KEY);');c.commit();c.close();os.chmod(path,0o600)
def header(sid,time='2026-01-01T00:00:00Z',parent=None):
 r={'type':'session','version':3,'id':sid,'timestamp':time,'cwd':'SYNTHETIC_PRIVATE_PATH'}
 if parent:r['parentSession']=str(parent)
 return r
def assistant(eid,time=1767229200000,value=10):
 return {'type':'message','id':eid,'timestamp':'2026-01-01T01:00:00Z','message':{'role':'assistant','provider':'fixture','model':'gpt-6.1-sol','timestamp':time,'stopReason':'stop','usage':{'input':value,'output':2,'cacheRead':3,'cacheWrite':0,'reasoning':1,'cacheWrite1h':0},'content':[{'type':'text','text':'SYNTHETIC_BODY_NEVER_STORE'}]}}
def write(path,rows):
 with path.open('w') as f:
  for row in rows:f.write(json.dumps(row)+'\n')
def row_count(path):
 c=sqlite3.connect(path);n=c.execute('select count(*) from usage_entries').fetchone()[0];c.close();return n

def source_scope_checks(base):
 policy=base/"scope-policy"; inside=policy/"tmp/inside"; outside=policy/"outside"; canonical=policy/"canonical"
 for p in [inside,outside,canonical,policy/"tmp-evil"]:p.mkdir(parents=True,exist_ok=True)
 oldroot,oldcanonical=m.ROOT,m.CANONICAL
 try:
  m.ROOT=policy;m.CANONICAL=canonical
  assert m.authorized_session_root(inside)==inside.resolve()
  assert m.authorized_session_root(inside/"../inside")==inside.resolve()
  assert m.authorized_session_root(canonical)==canonical.resolve()
  (policy/"tmp/alias").symlink_to(outside,target_is_directory=True)
  for p in [policy/"tmp/../outside",policy/"tmp/alias",policy/"tmp-evil"]:
   try:m.authorized_session_root(p);raise AssertionError("path escape admitted")
   except ValueError as e:assert str(e)=="source-scope-not-authorized"
 finally:m.ROOT=oldroot;m.CANONICAL=oldcanonical

def main():
 assert m.clean_tokens({'input':float('nan'),'output':float('inf'),'cacheRead':10**400,'cacheWrite':True})[0]==[None,None,None,None]
 base=pathlib.Path(tempfile.mkdtemp(prefix='history-fixture-',dir=ROOT/'tmp'));sessions=base/'sessions';sessions.mkdir();db=base/'usage.sqlite3';init_db(db);manifest=base/'install.json';manifest.write_text('{"synthetic":true}');os.chmod(manifest,0o600)
 source_scope_checks(base)
 parent=sessions/'parent.jsonl';child=sessions/'child.jsonl';clone=sessions/'clone.jsonl'
 old=assistant('entry-old');new=assistant('entry-new',1767315600000,20)
 write(parent,[header('parent'),old,{'type':'usage','id':'entry-extra','timestamp':'2026-01-01T02:00:00Z','provider':'fixture','model':'gpt-6.1-sol','kind':'new-unknown-kind','usage':{'input':5,'output':1,'cacheRead':0,'cacheWrite':0}}, {'type':'compaction','id':'compact','timestamp':'2026-01-01T03:00:00Z','summary':'SYNTHETIC_BODY_NEVER_STORE','usage':{'input':7,'output':1,'cacheRead':0,'cacheWrite':0}}, {'type':'branch_summary','id':'summary','timestamp':'2026-01-01T04:00:00Z','summary':'SYNTHETIC_BODY_NEVER_STORE','usage':{'input':2,'output':1}}])
 write(child,[header('child','2026-01-02T00:00:00Z',parent),old,new])
 write(clone,[header('clone','2026-01-03T00:00:00Z',child),old,new])
 # Same eight-character ID in an unrelated session is a separate paid call.
 write(sessions/'other.jsonl',[header('other'),assistant('entry-old',1767232800000,30)])
 write(sessions/'missing-parent.jsonl',[header('missing','2026-01-02T00:00:00Z',sessions/'absent.jsonl'),old,assistant('new-paid',1767322800000,40)])
 write(sessions/'missing-grandparent.jsonl',[header('grandchild','2026-01-03T00:00:00Z',sessions/'missing-parent.jsonl'),assistant('new-at-leaf',1767409200000,50)])
 # A paid branch not on a current leaf must remain counted. No context projection is used.
 write(sessions/'all-branches.jsonl',[header('branches'),assistant('branch-a',1767236400000,3),assistant('branch-b',1767240000000,4)])
 live_session=m.digest(m.digest(socket.gethostname()+':'+str(os.getuid()))[:32]+':parent');live_id=m.digest(live_session+':entry-old');c=sqlite3.connect(db);c.execute('insert into usage_entries values(?,?,?,?,?,?,?,?)',(live_id,live_session,1767229200000,'fixture/gpt-6.1-sol',10,2,3,0));c.commit();c.close()
 run=base/'preview';p=m.preview(sessions,run,db,0)
 assert p['summary']['matchedExisting']==1,p
 assert p['counters']['fork-copy-aliases']>=3 and p['counters']['ambiguous-candidates']>=1,p
 assert p['summary']['models']['unknown']['records']==2,p
 assert p['summary']['missingFields']['cacheRead']>=1,p
 for file in run.iterdir():
  if file.suffix=='.json':assert 'SYNTHETIC_BODY_NEVER_STORE' not in file.read_text() and 'SYNTHETIC_PRIVATE_PATH' not in file.read_text()
 c=sqlite3.connect(run/'stage.sqlite3');dump='\n'.join(c.iterdump());c.close();assert 'SYNTHETIC_BODY_NEVER_STORE' not in dump and 'SYNTHETIC_PRIVATE_PATH' not in dump
 original={f:m.file_hash(f) for f in sessions.iterdir()}
 # Append after preview: frozen prefixes stay verifiable; the tail is not silently imported.
 with parent.open('a') as f:f.write(json.dumps(assistant('after-freeze',1767243600000,99))+'\n')
 before=row_count(db)
 try:m.apply(run,sessions,db,manifest,base/'failed-backups',fail_after=1);raise AssertionError('failure not raised')
 except ValueError as e:assert str(e)=='synthetic-apply-failure'
 assert row_count(db)==before
 applied=m.apply(run,sessions,db,manifest,base/'backups');assert applied['inserted']==p['summary']['estimatedNew'];assert applied['filesAppendedBeyondSnapshot']==1
 assert row_count(db)==before+applied['inserted']
 repeated=m.apply(run,sessions,db,manifest,base/'backups');assert repeated['repeatedApplyNoChange'] and row_count(db)==before+applied['inserted']
 # A new realtime row and a realtime-confirmed imported canonical row survive.
 c=sqlite3.connect(db);c.execute('insert into usage_entries values(?,?,?,?,?,?,?,?)',('new-live','live',1767330000000,'fixture/gpt',9,2,0,0))
 confirmed=c.execute("select canonical_id from usage_aliases where canonical_id in (select id from usage_provenance) limit 1").fetchone()[0]
 c.execute('update usage_provenance set has_realtime=1 where id=?',(confirmed,));c.commit();c.close()
 rolled=m.rollback(applied['importId'],db,base/'backups');assert row_count(db)==before+2 and rolled['removedImportedOnlyRows']==applied['inserted']-1
 c=sqlite3.connect(db);assert c.execute('select count(*) from usage_aliases where canonical_id=?',(confirmed,)).fetchone()[0]>0;c.close()
 assert m.rollback(applied['importId'],db,base/'backups')['repeatedRollbackNoChange']
 for f,checksum in original.items():
  if f!=parent:assert m.file_hash(f)==checksum
 snapshot=sqlite3.connect(base/'backups'/applied['importId']/'usage-snapshot.sqlite3');assert snapshot.execute('select count(*) from usage_entries').fetchone()[0]==before;snapshot.close()
 # Keep a committed writer connection open: the new row exists only in WAL.
 waldb=base/'wal-only.sqlite3';init_db(waldb);writer=sqlite3.connect(waldb);writer.execute('PRAGMA wal_autocheckpoint=0');writer.execute('insert into usage_entries values(?,?,?,?,?,?,?,?)',('wal-row','live',1767330000000,'fixture/gpt',1,2,0,0));writer.commit()
 assert pathlib.Path(str(waldb)+'-wal').stat().st_size>0
 m.backup_consistent(waldb,manifest,base/'wal-backup')
 walcopy=sqlite3.connect(base/'wal-backup'/'usage-snapshot.sqlite3');assert walcopy.execute('select count(*) from usage_entries').fetchone()[0]==1;walcopy.close();writer.close()
 # Same stable ID changed payload is preserved as conflict, not overwritten.
 otherbase=base/'conflict-sessions';otherbase.mkdir();write(otherbase/'a.jsonl',[header('parent'),assistant('entry-old',1767229200000,999)])
 cp=m.preview(otherbase,base/'conflict-preview',db,0);assert cp['summary']['conflicts']==1 and cp['summary']['estimatedNew']==0
 # Changed prefixes are rejected before DB mutation; later appended files are out of snapshot.
 changed=base/'changed-sessions';changed.mkdir();source=changed/'one.jsonl';write(source,[header('changed'),assistant('same',1767229200000,8)])
 changedrun=base/'changed-preview';m.preview(changed,changedrun,db,0);write(source,[header('changed'),assistant('same',1767229200000,88)])
 count=row_count(db)
 try:m.apply(changedrun,changed,db,manifest,base/'changed-backups');raise AssertionError('changed prefix accepted')
 except ValueError as e:assert str(e) in ('source-prefix-changed','source-identity-or-prefix-changed')
 assert row_count(db)==count
 # Oversized/body lines are discarded with bounded buffering, not written into staging.
 edge=base/'edge-sessions';edge.mkdir();edgefile=edge/'one.jsonl';write(edgefile,[header('edge'),assistant('valid',1767229200000,6)])
 oldlimit=m.MAX_LINE;m.MAX_LINE=1024
 with edgefile.open('a') as f:f.write(json.dumps({'type':'message','id':'big','message':{'role':'user','content':'SYNTHETIC_BODY_NEVER_STORE'*1024}})+'\n');f.write('{"type":')
 ep=m.preview(edge,base/'edge-preview',db,0);m.MAX_LINE=oldlimit
 assert ep['counters']['oversized-lines']==1 and ep['counters']['incomplete-tail']==1
 print(json.dumps({'ok':True,'synthetic':True,'cases':['realpath-source-scope','ancestor-symlink-escape','realtime-key-overlap','fork-clone-alias','unrelated-id-collision','all-branches','missing-parent-ambiguous','missing-grandparent-ambiguous','rollback-retains-live-alias','usage-kind','unknown-summary-model','missing-fields','no-body-or-path-stored','append-frozen-prefix','failure-rollback','duplicate-apply','new-realtime-preserved','backup-api-consistency','committed-wal-backup','same-id-conflict']}))
if __name__=='__main__':main()
