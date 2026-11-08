import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { displayBudget } from "../src/budget.ts";
import { encode } from "../src/protocol.ts";
import { MissionDecisionObserver, validMissionDecisions } from "../src/mission-decisions.ts";

const at=1730000000000;
const open=(id:string,extra:Record<string,unknown>={})=>({id,status:"open",createdAt:new Date(at-100).toISOString(),...extra});
const closed=(id:string,extra:Record<string,unknown>={})=>({...open(id),status:"resolved",resolvedAt:new Date(at).toISOString(),...extra});
function apply(observer:MissionDecisionObserver,call:string,rows:unknown[],time=at,finalRows=rows,schemaVersion:unknown=1){
  const details=(decisions:unknown[])=>({mode:"management",missionId:"typed-mission",mission:{schemaVersion,id:"typed-mission",updatedAt:new Date(time).toISOString(),decisions}});
  observer.start(call);observer.result({toolName:"subagent",toolCallId:call,isError:false,input:{action:"mission.show",options:{missionId:"typed-mission"}},details:details(rows)});
  return observer.end(call,{details:details(finalRows)},false,time+10);
}
test("schema-1 and fenced schema-2 sources share the existing content-free projection",()=>{
  const rows=[closed("d1",{closeReason:"superseded",supersededBy:"d2"}),open("d2",{supersedes:"d1",title:"PRIVATE_TITLE"})];
  const projections=[];
  for(const version of [1,2]){
    const observer=new MissionDecisionObserver();apply(observer,"schema-"+version,rows,at,rows,version);
    const projection=observer.read();
    assert.equal(projection.version,1,"source schema does not change the wire format");
    assert.equal(projection.missions[0].coverage,"complete");
    assert.ok(validMissionDecisions(projection));
    assert.ok(!JSON.stringify(projection).includes("PRIVATE_TITLE"));
    projections.push(projection.missions[0]);
  }
  assert.deepEqual(projections[1],projections[0]);
  for(const version of [0,3,"2",null]){
    const observer=new MissionDecisionObserver();
    apply(observer,"unsupported",rows,at,rows,version);
    assert.equal(observer.read().missions[0].coverage,"unavailable");
    assert.deepEqual(observer.read().missions[0].decisions,[]);
  }
});

test("typed metadata preserves replacement intent, actual closure and legacy unknown as distinct facts",()=>{
  const observer=new MissionDecisionObserver();
  apply(observer,"intent",[open("d1"),open("d2",{supersedes:"d1"})]);
  let record=observer.read().missions[0];
  assert.equal(record.counts?.open,2);
  assert.equal(record.decisions.find(d=>d.id==="d2")?.supersedes,"d1");
  assert.equal(record.decisions.find(d=>d.id==="d1")?.supersededBy,undefined);
  apply(observer,"closure",[closed("d1",{closeReason:"superseded",supersededBy:"d2"}),open("d2",{supersedes:"d1"})],at+1);
  record=observer.read().missions[0];
  assert.equal(record.decisions.find(d=>d.id==="d1")?.closeReason,"superseded");
  assert.equal(record.decisions.find(d=>d.id==="d1")?.supersededBy,"d2");
  assert.deepEqual(record.counts,{open:1,resolved:1,total:2});
  assert.ok(validMissionDecisions(observer.read()));
  apply(observer,"answer-gap",[closed("d1",{closeReason:"answered"}),open("d2",{supersedes:"d1"})],at+2);
  assert.equal(observer.read().missions[0].decisions.find(d=>d.id==="d1")?.closeReason,"answered");
  assert.equal(observer.read().missions[0].decisions.find(d=>d.id==="d1")?.supersededBy,undefined);
  apply(observer,"withdraw",[closed("d1",{closeReason:"withdrawn"}),open("d2",{supersedes:"d1"})],at+3);
  assert.equal(observer.read().missions[0].decisions.find(d=>d.id==="d1")?.closeReason,"withdrawn");
  apply(observer,"legacy",[closed("d1"),open("d2")],at+4);
  assert.equal(observer.read().missions[0].decisions.find(d=>d.id==="d1")?.closeReason,undefined,"legacy resolved is not retroactively answered");
});

test("multiple candidates, equal creation timestamps and later closed replacements remain original metadata",()=>{
  const observer=new MissionDecisionObserver();
  const rows=[closed("d1",{closeReason:"superseded",supersededBy:"d3"}),open("d2",{supersedes:"d1"}),closed("d3",{supersedes:"d1",closeReason:"withdrawn"})];
  apply(observer,"candidates",rows);
  const projection=observer.read(), record=projection.missions[0];
  assert.equal(record.coverage,"complete");assert.ok(validMissionDecisions(projection));
  assert.equal(record.decisions.find(d=>d.id==="d1")?.supersededBy,"d3");
  assert.equal(record.decisions.find(d=>d.id==="d2")?.supersedes,"d1");
  assert.equal(record.decisions.find(d=>d.id==="d3")?.closeReason,"withdrawn");
  // A candidate may itself later be replaced; do not require a historic chosen
  // replacement to still be open in a current readback.
  apply(observer,"chain",[closed("d1",{closeReason:"superseded",supersededBy:"d2"}),closed("d2",{supersedes:"d1",closeReason:"superseded",supersededBy:"d3"}),open("d3",{supersedes:"d2"})],at+1);
  assert.equal(observer.read().missions[0].coverage,"complete");
  apply(observer,"clock",[closed("d1",{closeReason:"superseded",supersededBy:"d2",resolvedAt:new Date(at-300).toISOString()}),open("d2",{supersedes:"d1",createdAt:new Date(at-200).toISOString()})],at+2);
  assert.ok(validMissionDecisions(observer.read()));assert.equal(observer.read().missions[0].coverage,"complete","owner order is array order, not a monotonic-clock assumption");
});

test("malformed typed rows and impossible source links become unavailable, never a typed fact",()=>{
  const invalid:unknown[][]=[
    [open("d1",{closeReason:"answered"})],
    [closed("d1",{closeReason:"approved"})],
    [closed("d1",{closeReason:"answered",resolvedAt:undefined})],
    [closed("d1",{closeReason:null})],
    [open("d1",{supersedes:null})],
    [open("d1",{supersedes:"d1"})],
    [open("d1",{supersedes:"missing"})],
    [open("d2",{supersedes:"d1"}),open("d1")],
    [open("d1",{supersedes:"d2"}),open("d2",{supersedes:"d1"})],
    [closed("d1",{supersededBy:"d2"}),open("d2",{supersedes:"d1"})],
    [closed("d1",{closeReason:"answered",supersededBy:"d2"}),open("d2",{supersedes:"d1"})],
    [closed("d1",{closeReason:"superseded"}),open("d2",{supersedes:"d1"})],
    [closed("d1",{closeReason:"superseded",supersededBy:"d2"}),open("d2")],
    [closed("d1",{closeReason:"superseded",supersededBy:"d1"})],
    [open("d1"),open("d1")],
    [open("d1"),open("d2",{supersedes:"/private/id"})],
    [open("d1"),open("d2",{supersedes:"id..bad"})],
    [open("d1"),open("d2",{supersedes:"a".repeat(129)})],
    [open("d1"),open("d2",{supersedes:"sk-12345678901234567890"})],
    [closed("d1",{closeReason:"superseded",supersededBy:null})],
  ];
  for(const [i,rows] of invalid.entries()){
    const observer=new MissionDecisionObserver();apply(observer,"invalid-"+i,rows);
    assert.equal(observer.read().missions[0].coverage,"unavailable","bad typed source "+i);
    assert.equal(observer.read().missions[0].counts,undefined);
    assert.deepEqual(observer.read().missions[0].decisions,[]);
  }
});

test("typed whitelist never invokes getters, proxies, toJSON or private text while finalizing",()=>{
  let reads=0;
  const row=open("d2",{supersedes:"d1",title:"PRIVATE_TITLE"});
  for(const key of ["prompt","resolution","options","toJSON"]){Object.defineProperty(row,key,{get(){reads++;throw Error("private getter");}});}
  const observer=new MissionDecisionObserver();apply(observer,"safe",[open("d1"),row]);
  assert.equal(reads,0);assert.equal(observer.read().missions[0].coverage,"complete");assert.ok(!JSON.stringify(observer.read()).includes("PRIVATE_"));
  for(const field of ["closeReason","supersedes","supersededBy"]){
    const poisoned=open("d1");Object.defineProperty(poisoned,field,{get(){reads++;throw Error("typed getter");}});
    const check=new MissionDecisionObserver();apply(check,field,[poisoned]);
    assert.equal(reads,0);assert.equal(check.read().missions[0].coverage,"unavailable");
  }
  const proxy=new Proxy({}, {get(){reads++;throw Error();},getOwnPropertyDescriptor(){reads++;throw Error();}});
  const check=new MissionDecisionObserver();apply(check,"proxy",[proxy]);assert.equal(reads,0);assert.equal(check.read().missions[0].coverage,"unavailable");
});

test("typed-only changes participate in final and same-time fingerprints without renewing old originals",()=>{
  const intent=[open("d1"),open("d2",{supersedes:"d1"})],plain=[open("d1"),open("d2")];
  const mismatch=new MissionDecisionObserver();apply(mismatch,"final-diff",intent,at,plain);
  assert.equal(mismatch.read().missions[0].reason,"finalized-mismatch");
  const observer=new MissionDecisionObserver();apply(observer,"intent",intent);
  const first=observer.read();assert.equal(apply(observer,"same",intent),false);assert.deepEqual(observer.read(),first);
  apply(observer,"conflict",plain);assert.equal(observer.read().missions[0].reason,"same-time-conflict");
  assert.equal(apply(observer,"original",intent),false);
  apply(observer,"new",intent,at+1);assert.equal(observer.read().missions[0].coverage,"complete");
  const current=observer.read();assert.equal(apply(observer,"late",plain,at),false);assert.deepEqual(observer.read(),current);
});

test("additive typed wire validates visible links without inferring budget-omitted peers",()=>{
  const fixture=JSON.parse(readFileSync(new URL("../../../Fixtures/mission-decisions-typed-v1.json",import.meta.url),"utf8"));
  assert.ok(validMissionDecisions(fixture));
  const malformed=(change:(value:typeof fixture)=>void)=>{const value=structuredClone(fixture);change(value);assert.equal(validMissionDecisions(value),false);};
  malformed(v=>v.missions[0].decisions[0].supersedes="dangling");
  malformed(v=>v.missions[0].decisions[0].closeReason="answered");
  malformed(v=>v.missions[0].decisions[0].supersedes=null);
  malformed(v=>v.missions[0].decisions[2].supersededBy="answered");
  malformed(v=>v.missions[0].decisions[2].closeReason="withdrawn");
  malformed(v=>v.missions[0].decisions[2].supersedes="d2");
  const omitted=structuredClone(fixture);omitted.coverage="partial";omitted.missions[0].coverage="partial";
  omitted.missions[0].decisions=omitted.missions[0].decisions.filter((d:{id:string})=>d.id!=="d1");omitted.missions[0].omitted=1;
  assert.ok(validMissionDecisions(omitted),"same-record ref may point at a whole-row omitted peer; not a new closure fact");
});

test("whole typed rows respect display/frame bounds and validate hidden source refs before truncation",()=>{
  const rows=Array.from({length:512},(_,i)=>open("id-"+i.toString().padStart(4,"0")+"x".repeat(116),i?{supersedes:"id-"+(i-1).toString().padStart(4,"0")+"x".repeat(116)}:{}));
  const observer=new MissionDecisionObserver();apply(observer,"many",rows);
  const projection=observer.read(),record=projection.missions[0];
  assert.equal(record.counts?.total,512);assert.ok(record.omitted>0&&record.decisions.length<=32);assert.ok(validMissionDecisions(projection));
  assert.ok(record.decisions.reduce((n,d)=>n+Buffer.byteLength(JSON.stringify(d))+1,0)<=2800);
  const wire=JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json",import.meta.url),"utf8"));wire.snapshot.missionDecisions=projection;wire.snapshot=displayBudget(wire.snapshot);assert.ok(encode(wire).length<=65537);
  Object.assign(rows[511],{supersedes:"hidden-dangling"});apply(observer,"bad-hidden",rows,at+1);
  assert.equal(observer.read().missions[0].coverage,"unavailable");
});
