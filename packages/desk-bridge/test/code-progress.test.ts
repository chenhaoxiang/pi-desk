import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CODE_PROGRESS_STATES, projectCodeProgress, validCodeProgress } from "../src/code-progress.ts";
import { GovernanceClient, projectWorkSnapshot, WORK_CHANGED, WORK_QUERY, WORK_REPLY } from "../src/governance-client.ts";
import { encode, validate } from "../src/protocol.ts";
const fixture = JSON.parse(readFileSync(new URL("../../../Fixtures/code-progress-v1.json",import.meta.url),"utf8"));
const old = JSON.parse(readFileSync(new URL("../../../Fixtures/work-results-v1.json",import.meta.url),"utf8"));
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
function sidecar(seq = fixture.seq) { const {observerEpoch,...p} = structuredClone(fixture); return {...p,seq}; }
function snapshot(codeProgress: unknown = sidecar(), epoch = "epoch-a", seq = 4) {
  return {version:1,hostSessionId:"host-a",observerEpoch:epoch,seq,scope:"session-recent-observations",coverage:"observed",observations:[...old.results.map((r:object)=>({...r,kind:"result"})),...old.handoffs.map((r:object)=>({...r,kind:"handoff"}))],omitted:0,authorization:"none",readOnly:true,executable:false,codeProgress};
}
function bus() {
  const listeners = new Map<string,Set<(v:any)=>void>>(); let queries=0;
  return {count:()=>queries,on(name:string,fn:(v:any)=>void){const set=listeners.get(name)??new Set();set.add(fn);listeners.set(name,set);return()=>{set.delete(fn);};},emit(name:string,value:unknown){if(name===WORK_QUERY)queries++;for(const fn of listeners.get(name)??[])fn(value);}};
}
function host() {
  const events=bus(); let source=snapshot();
  events.on(WORK_QUERY,q=>events.emit(WORK_REPLY+q.requestId,{version:1,requestId:q.requestId,snapshot:source}));
  const client=new GovernanceClient(events,"host-a",()=>{},15);
  return {events,client,set:(value:ReturnType<typeof snapshot>)=>{source=value;},send:(value:ReturnType<typeof snapshot>)=>events.emit(WORK_CHANGED,{version:1,snapshot:value})};
}

test("optional shared progress fixture is bounded and every allowed triple is non-authorizing",()=>{
  assert.ok(validCodeProgress(fixture)); const p=projectCodeProgress(sidecar(),"epoch-a")!;assert.equal(p.observations.length,3);
  for(const [phase,waitReason,nextAction] of CODE_PROGRESS_STATES){const value=sidecar();Object.assign(value.observations[0],{phase,waitReason,nextAction});assert.ok(projectCodeProgress(value,"epoch-a"));}
  const wire=JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json",import.meta.url),"utf8"));validate(wire);wire.snapshot!.codeProgress=p;validate(wire);assert.ok(encode(wire).length<=65537);
});
test("legacy result projection ignores even an accessor sidecar rather than changing result semantics",()=>{
  const raw=snapshot();const expected=projectWorkSnapshot(raw,"host-a");let reads=0;
  Object.defineProperty(raw,"codeProgress",{get(){reads++;throw Error("legacy touched progress");}});
  assert.deepEqual(projectWorkSnapshot(raw,"host-a"),expected);assert.equal(reads,0);
});
test("sidecar validation rejects unsupported fields, unsafe references, conflicting triples and oversize",()=>{
  for(const change of [(v:any)=>v.version=2,(v:any)=>v.observations[0].accepted=true,(v:any)=>v.observations[0].authorization="admitted",(v:any)=>v.observations[0].binding.headSha=undefined,(v:any)=>v.observations[0].waitReason="none",(v:any)=>v.observations[0].repository="https://github.com/example/project",(v:any)=>v.observations[0].pullRequest=0,(v:any)=>v.seq=1]){
    const value=sidecar();change(value);assert.equal(projectCodeProgress(value,"epoch-a"),undefined);
  }
  const large=sidecar(16);large.observations=Array.from({length:16},(_,i)=>({...fixture.observations[0],seq:i+1,binding:{...fixture.observations[0].binding,runId:"r".repeat(128),sessionId:"s".repeat(128)},repository:"p".repeat(90)+"/"+"r".repeat(90)}));assert.ok(Buffer.byteLength(JSON.stringify(large))>5400);assert.equal(projectCodeProgress(large,"epoch-a"),undefined);
  let reads=0;const access=sidecar();Object.defineProperty(access.observations[0],"phase",{get(){reads++;throw Error();}});assert.equal(projectCodeProgress(access,"epoch-a"),undefined);assert.equal(reads,0);
});
test("progress updates at unchanged outer seq leave v1 results and original times untouched",async()=>{
  const h=host();h.client.start();await tick();const before=structuredClone(h.client.read());
  const next=sidecar(4);next.observations.push({...next.observations[2],seq:4,observedAt:1730000000003,phase:"head-checks",waitReason:"required_checks_failed",nextAction:"inspect_required_checks"});
  h.set(snapshot(next));h.send(snapshot(next));await tick();
  assert.deepEqual(h.client.read(),before);assert.equal(h.client.readCodeProgress().seq,4);assert.equal(h.client.readCodeProgress().observations.at(-1)?.waitReason,"required_checks_failed");assert.equal(h.events.count(),1);
  const current=structuredClone(h.client.readCodeProgress());h.client.refresh();assert.deepEqual(h.client.readCodeProgress(),current);assert.deepEqual(h.client.read(),before);h.client.close();
});
test("missing or invalid progress is only stale/unknown in its lane and same-seq conflict needs newer progress",async()=>{
  const h=host();h.client.start();await tick();const before=structuredClone(h.client.read());
  h.send({...snapshot(),codeProgress:undefined});await tick();
  assert.equal(h.client.readCodeProgress().stale,true);assert.deepEqual(h.client.read(),before);
  h.send(snapshot());await tick();assert.equal(h.client.readCodeProgress().stale,undefined);
  const conflict=sidecar();conflict.observations[2].observedAt++;
  h.send(snapshot(conflict));await tick();assert.equal(h.client.readCodeProgress().stale,true);assert.deepEqual(h.client.read(),before);
  h.send(snapshot());await tick();assert.equal(h.client.readCodeProgress().stale,true);
  h.send(snapshot(sidecar(4)));await tick();assert.equal(h.client.readCodeProgress().stale,undefined);assert.equal(h.client.readCodeProgress().seq,4);h.client.close();
});
test("same-tick equal-sequence contradictions cannot be coalesced back into a current snapshot",async()=>{
  const h=host();h.client.start();await tick();const result=structuredClone(h.client.read());
  const conflict=sidecar();conflict.observations[2].observedAt++;
  h.send(snapshot(conflict));h.send(snapshot());await tick();
  assert.equal(h.client.readCodeProgress().stale,true,"queued contradiction followed by the original still latches conflict");
  assert.deepEqual(h.client.read(),result);
  h.send(snapshot());await tick();assert.equal(h.client.readCodeProgress().stale,true);
  h.send(snapshot(sidecar(4)));await tick();assert.equal(h.client.readCodeProgress().stale,undefined);
  const first=sidecar(5),different=sidecar(5);different.observations[0].observedAt++;
  h.send(snapshot(first));h.send(snapshot(different));h.send(snapshot(first));await tick();
  assert.equal(h.client.readCodeProgress().stale,true,"a not-yet-accepted sequence also retains middle contradictions");
  h.send(snapshot(sidecar(6)));await tick();assert.equal(h.client.readCodeProgress().stale,undefined);
  const lastConflict=sidecar(6);lastConflict.observations[1].observedAt++;
  h.send(snapshot(lastConflict));h.send(snapshot(sidecar(7)));await tick();
  assert.equal(h.client.readCodeProgress().seq,7);assert.equal(h.client.readCodeProgress().stale,undefined,"a genuinely newer sequence in the same batch clears the older conflict");h.client.close();
});
test("producer unavailable retains original rows and advances only progress watermark; new epoch resets it",async()=>{
  const h=host();h.client.start();await tick();const before=structuredClone(h.client.read()), rows=structuredClone(h.client.readCodeProgress().observations);
  const unavailable={...sidecar(4),coverage:"unavailable"};h.send(snapshot(unavailable));await tick();
  assert.equal(h.client.readCodeProgress().seq,4);assert.equal(h.client.readCodeProgress().stale,true);assert.deepEqual(h.client.readCodeProgress().observations,rows);assert.deepEqual(h.client.read(),before);
  h.send(snapshot());await tick();assert.equal(h.client.readCodeProgress().seq,4);assert.equal(h.client.readCodeProgress().stale,true);
  const reset={...sidecar(0),coverage:"not-observed",observations:[]};h.set(snapshot(reset,"epoch-b"));h.send(snapshot(reset,"epoch-b"));await tick();
  assert.equal(h.client.readCodeProgress().seq,0);assert.equal(h.client.readCodeProgress().observerEpoch,"epoch-b");assert.equal(h.client.readCodeProgress().observations.length,0);
  h.send(snapshot(sidecar(9),"epoch-a"));await tick();assert.equal(h.client.readCodeProgress().observerEpoch,"epoch-b");h.client.close();
});
test("coalescing retains each lane's newest sequence; a bad old lane does not erase valid progress",async()=>{
  const h=host();h.client.start();await tick();h.send(snapshot(sidecar(5),"epoch-a",5));h.send(snapshot(sidecar(6),"epoch-a",4));await tick();
  assert.equal(h.client.read().observerSeq,5);assert.equal(h.client.readCodeProgress().seq,6);
  const invalid={...snapshot(sidecar(7),"epoch-a",6),observations:[{kind:"unexpected"}]};h.send(invalid as never);await tick();assert.equal(h.client.read().coverage,"unavailable");assert.equal(h.client.readCodeProgress().seq,7);h.client.close();
});
