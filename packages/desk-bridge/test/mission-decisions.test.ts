import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MissionDecisionObserver, validMissionDecisions } from "../src/mission-decisions.ts";
import { displayBudget } from "../src/budget.ts";
import { encode, validate } from "../src/protocol.ts";
const at=1730000000000;
const rows=[{id:"a",status:"resolved",createdAt:new Date(at-1000).toISOString(),resolvedAt:new Date(at).toISOString()},{id:"b",status:"open",createdAt:new Date(at-1000).toISOString()}];
const details=(time=at,decisions:unknown=rows)=>({mode:"management",missionId:"mission-one",mission:{schemaVersion:1,id:"mission-one",updatedAt:new Date(time).toISOString(),decisions}});
function apply(o:MissionDecisionObserver,id:string,value=details(),end=value){o.start(id);o.result({toolName:"subagent",toolCallId:id,isError:false,input:{action:"mission.show",options:{missionId:"mission-one"}},details:value});return o.end(id,{details:end},false,at+100);}
test("shared decision fixture is optional and bounded; finalized partial resolution stays explicit",()=>{
 const fixture=JSON.parse(readFileSync(new URL("../../../Fixtures/mission-decisions-v1.json",import.meta.url),"utf8"));assert.ok(validMissionDecisions(fixture));
 const wire=JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json",import.meta.url),"utf8"));validate(wire);wire.snapshot!.missionDecisions=fixture;validate(wire);assert.ok(encode(wire).length<65536);
 const o=new MissionDecisionObserver();assert.equal(o.read().coverage,"not-observed");assert.ok(apply(o,"one"));assert.deepEqual(o.read().missions[0].counts,{open:1,resolved:1,total:2});assert.equal(o.read().missions[0].decisions[0].id,"b");assert.ok(validMissionDecisions(o.read()));
});
test("tool_result cannot publish before final end or patch another extension's result",()=>{
 const o=new MissionDecisionObserver(),value=details();o.start("one");o.result({toolName:"subagent",toolCallId:"one",isError:false,input:{action:"mission.show",options:{missionId:"mission-one"}},details:value});
 assert.equal(o.read().coverage,"not-observed");const changed=details(at+1);
 assert.ok(o.end("one",{details:changed},false,at+2));assert.equal(o.read().missions[0].coverage,"unavailable");assert.equal(o.read().missions[0].counts,undefined);
 const p=new MissionDecisionObserver();p.start("failed");p.result({toolName:"subagent",toolCallId:"failed",isError:false,input:{action:"mission.show",options:{missionId:"mission-one"}},details:value});assert.equal(p.end("failed",{details:value},true,at),false);assert.equal(p.read().coverage,"not-observed");
});
test("old originals cannot overwrite newer records; equal-time conflicts remain unknown until newer source",()=>{
 const o=new MissionDecisionObserver();apply(o,"new",details(at+10));const snapshot=o.read();
 assert.equal(apply(o,"old",details(at,rows.map(r=>({...r,status:"open",resolvedAt:undefined})))),false);assert.deepEqual(o.read(),snapshot);
 assert.equal(apply(o,"repeat",details(at+10)),false);assert.deepEqual(o.read(),snapshot);
 assert.ok(apply(o,"conflict",details(at+10,rows.map(r=>({...r,status:"open",resolvedAt:undefined})))));assert.equal(o.read().missions[0].reason,"same-time-conflict");
 assert.equal(apply(o,"repeat-old",details(at+10)),false);assert.equal(o.read().missions[0].counts,undefined);
 apply(o,"missing",{...details(),mission:{...details().mission,updatedAt:undefined}} as never);assert.equal(o.read().missions[0].counts,undefined);
 assert.ok(apply(o,"later",details(at+20)));assert.deepEqual(o.read().missions[0].counts,{open:1,resolved:1,total:2});
});
test("scope replacement, absent data and accessors never become empty/complete or read private fields",()=>{
 let reads=0;const value=details();Object.defineProperty(value.mission,"title",{get(){reads++;throw Error();}});Object.defineProperty(value.mission,"resolution",{get(){reads++;throw Error();}});
 const o=new MissionDecisionObserver();apply(o,"safe",value);assert.equal(reads,0);
 o.start("late");o.result({toolName:"subagent",toolCallId:"late",isError:false,input:{action:"mission.show",missionId:"mission-one"},details:value});o.reset();assert.equal(o.end("late",{details:value},false,at),false);assert.equal(o.read().coverage,"not-observed");
 const absent={...details(at+1),mission:{...details(at+1).mission,decisions:undefined}};apply(o,"absent",absent as never);assert.equal(o.read().missions[0].counts,undefined);
 apply(o,"empty",details(at+2,[]));assert.equal(o.read().missions[0].counts?.total,0);
});
test("known watermarks survive missing timestamps; native Date.parse formats are metadata only",()=>{
 const o=new MissionDecisionObserver();apply(o,"latest",details(at+10));
 apply(o,"bad",{...details(),mission:{...details().mission,updatedAt:undefined}} as never);
 assert.equal(o.read().missions[0].counts,undefined);
 assert.equal(apply(o,"late",details(at)),false);assert.equal(o.read().missions[0].counts,undefined);
 const later=details(at+1000);later.mission.updatedAt=new Date(at+1000).toUTCString();
 assert.ok(apply(o,"valid",later));assert.equal(o.read().missions[0].sourceUpdatedAt,at+1000);
});
test("wrong action, identity, proxies and accessors are not read or published",()=>{
 for(const input of [{action:"mission.list"},{action:"mission.show",options:{missionId:"wrong"}},{action:"mission.show",missionId:"mission-one",options:{missionId:"wrong"}}]){
  const o=new MissionDecisionObserver();o.start("x");o.result({toolName:"subagent",toolCallId:"x",isError:false,input,details:details()});assert.equal(o.end("x",{details:details()},false,at),false);
 }
 let reads=0;const value=details();Object.defineProperty(value.mission,"decisions",{get(){reads++;throw Error("accessor read");}});
 const o=new MissionDecisionObserver();apply(o,"accessor",value);assert.equal(reads,0);assert.equal(o.read().missions[0].counts,undefined);
 const proxy=new Proxy({}, {getOwnPropertyDescriptor(){throw Error("proxy read");}});
 assert.equal(validMissionDecisions(proxy),false);
});
test("stable observed order and record evictions are separate from current display omissions",()=>{
 const o=new MissionDecisionObserver();
 const put=(id:string,time:number)=>{const value=details(time);value.missionId=id;value.mission.id=id;o.start(id);o.result({toolName:"subagent",toolCallId:id,isError:false,input:{action:"mission.show",options:{missionId:id}},details:value});o.end(id,{details:value},false,time);};
 put("a",at);put("b",at);put("a",at+1);assert.deepEqual(o.read().missions.map(m=>m.workRef.key),["a","b"]);
 for(let i=0;i<17;i++)put("mission-"+i,at+i);
 assert.equal(o.read().evictedRecords,3);assert.ok(o.read().omittedMissions>=0);assert.equal(o.read().coverage,"partial");assert.ok(validMissionDecisions(o.read()));
 o.reset();assert.equal(o.read().evictedRecords,0);
});
test("oversized originals are unavailable; display omissions preserve native counts and frame limit",()=>{
 const o=new MissionDecisionObserver();apply(o,"huge",details(at,Array(513).fill(rows[0])));assert.equal(o.read().missions[0].coverage,"unavailable");
 apply(o,"many",details(at+1,Array.from({length:512},(_,i)=>({...rows[1],id:"id-"+i}))));const p=o.read();assert.equal(p.coverage,"partial");assert.equal(p.missions[0].counts?.total,512);assert.ok(p.missions[0].decisions.length<=32);assert.ok(p.missions[0].omitted>0);assert.ok(validMissionDecisions(p));
 const wire=JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json",import.meta.url),"utf8"));wire.snapshot.missionDecisions=p;wire.snapshot=displayBudget(wire.snapshot);assert.ok(encode(wire).length<=65537);
});
