import test from "node:test";
import assert from "node:assert/strict";
import { GovernanceClient, projectWorkSnapshot, WORK_CHANGED, WORK_QUERY, WORK_REPLY } from "../src/governance-client.ts";
import { readFileSync } from "node:fs";
const fixture = JSON.parse(readFileSync(new URL("../../../Fixtures/work-results-v1.json", import.meta.url), "utf8"));
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
function snapshot(epoch = "epoch-a", seq = 4) {
  return { version:1, hostSessionId:"host-a", observerEpoch:epoch, seq, scope:"session-recent-observations", coverage:"observed", observations:[...fixture.results.map((r:object) => ({...r,kind:"result"})),...fixture.handoffs.map((r:object) => ({...r,kind:"handoff"}))], omitted:0, authorization:"none", readOnly:true, executable:false };
}
function bus() {
  const listeners = new Map<string, Set<(v: any) => void>>(); const emitted: {name:string;value:any}[] = [];
  return { emitted, on(name: string, fn: (v: any) => void) { const set = listeners.get(name) ?? new Set(); set.add(fn); listeners.set(name, set); return () => { set.delete(fn); }; }, emit(name: string, value: unknown) { emitted.push({ name, value }); for (const fn of listeners.get(name) ?? []) fn(value); } };
}
test("frozen Vista envelope reads existing observations, retaining original time and foreign child binding", async () => {
  const events = bus(); let changes = 0, source = snapshot();
  events.on(WORK_QUERY, q => events.emit(WORK_REPLY + q.requestId, {version:1,requestId:q.requestId,snapshot:source}));
  const client = new GovernanceClient(events, "host-a", () => { changes++; }, 50); client.start(); await tick();
  assert.equal(client.read().coverage,"observed"); assert.equal(client.read().results[0].observation.binding?.sessionId,"session-a");
  const before = structuredClone(client.read()), count=changes; client.refresh();
  assert.deepEqual(client.read(),before); assert.equal(changes,count,"query cannot refresh original result time or acceptance");
  assert.ok(events.emitted.every(e=>e.name===WORK_QUERY||e.name.startsWith(WORK_REPLY)),"no original owner-result/readOwner request");
  source = {...source, seq:5}; events.emit(WORK_CHANGED,{version:1,snapshot:source}); await tick();
  assert.equal(client.read().observerSeq,5);
  events.emit(WORK_CHANGED,{version:1,snapshot:{...source,seq:4}}); await tick(); assert.equal(client.read().observerSeq,5);
  source={...source,seq:7}; events.emit(WORK_CHANGED,{version:1,snapshot:source}); events.emit(WORK_CHANGED,{version:1,snapshot:{...source,seq:6}}); await tick(); assert.equal(client.read().observerSeq,7,"coalescing cannot replace a newer queued update with a late older packet");
  const last=changes; client.close(); events.emit(WORK_CHANGED,{version:1,snapshot:source}); await tick(); assert.equal(changes,last);
});
test("new epoch is reconciled through exact query; retired epoch and wrong host cannot replace it", async () => {
  const events=bus(); let source=snapshot();
  events.on(WORK_QUERY,q=>events.emit(WORK_REPLY+q.requestId,{version:1,requestId:q.requestId,snapshot:source}));
  const client=new GovernanceClient(events,"host-a",()=>{},50); client.start(); await tick();
  source=snapshot("epoch-b"); events.emit(WORK_CHANGED,{version:1,snapshot:source}); await tick();
  assert.equal(client.read().observerEpoch,"epoch-b");
  const queries=events.emitted.filter(e=>e.name===WORK_QUERY).length;
  events.emit(WORK_CHANGED,{version:1,snapshot:snapshot("epoch-a",8)});
  events.emit(WORK_CHANGED,{version:1,snapshot:{...source,hostSessionId:"other-host",seq:9}}); await tick();
  assert.equal(client.read().observerEpoch,"epoch-b"); assert.equal(events.emitted.filter(e=>e.name===WORK_QUERY).length,queries);
  client.close();
});
test("absent or wrong-address owner times out to unavailable without inventing an empty work list", async () => {
  const events=bus(); const client=new GovernanceClient(events,"host-a",()=>{},10); client.start(); await tick();
  const q=events.emitted.find(e=>e.name===WORK_QUERY)!.value;
  events.emit(WORK_REPLY+q.requestId,{version:1,requestId:q.requestId,snapshot:{...snapshot(),hostSessionId:"other"}});
  await new Promise(resolve=>setTimeout(resolve,25)); assert.equal(client.read().coverage,"unavailable");
  events.emit(WORK_REPLY+q.requestId,{version:1,requestId:q.requestId,snapshot:snapshot()}); assert.equal(client.read().coverage,"unavailable","expired reply is inert");
  client.close();
});
test("source protocol is metadata only, bounded, and keeps null binding unresolved", () => {
  const source=snapshot();
  assert.equal(projectWorkSnapshot({...source,authorization:"admitted"},"host-a"),undefined);
  assert.equal(projectWorkSnapshot({...source,observerEpoch:"/private"},"host-a"),undefined);
  assert.equal(projectWorkSnapshot({...source,observations:Array(17).fill(source.observations[0])},"host-a"),undefined);
  assert.equal(projectWorkSnapshot({...source,coverage:"not-observed"},"host-a"),undefined);
  const empty=projectWorkSnapshot({...source,coverage:"not-applicable",seq:0,observations:[]},"host-a"); assert.equal(empty?.coverage,"not-applicable");
  const unknown={...fixture.results[0],observation:{binding:null,decision:"reconcile_required",outcome:"unknown",reasonCode:"binding_invalid",authorization:"none",readOnly:true},kind:"result"};
  assert.equal(projectWorkSnapshot({...source,observations:[unknown]},"host-a")?.results[0].observation.binding,null);
});
