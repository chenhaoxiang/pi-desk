import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { createHost, until } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { WORK_QUERY, WORK_REPLY, WORK_CHANGED } from "../packages/desk-bridge/src/governance-client.ts";

await mkdir("tmp", {recursive:true});
const root=await mkdtemp(resolve("tmp/governance-native-")), records=[];
let host, server, observer, ownerReads=0, queryReads=0, source;
const socket=process.argv.includes("--socket");
try {
  if(socket) {
    await mkdir(join(root,"run"),{mode:0o700}); process.env.PI_DESK_SOCKET=join(root,"run","desk.sock"); process.env.PI_DESK_PEER_CHECK=resolve(".build/debug/PiDeskPeerCheck");
    server=spawn(resolve(".build/debug/PiDeskTransportTests"),["--serve",process.env.PI_DESK_SOCKET],{stdio:["pipe","pipe","inherit"]});
    let ready=false,carry="";
    server.stdout.on("data",bytes=>{carry+=String(bytes);while(carry.includes("\n")){const at=carry.indexOf("\n"),row=JSON.parse(carry.slice(0,at));carry=carry.slice(at+1);if(row.event==="socket-ready")ready=true;if(row.event==="record"){records.push(row.record);if(records.length>100)records.shift();}}});
    await until(()=>ready);
  }
  const native=process.env.PI_VISTA_WORK_OBSERVER;
  if(native) {
    const module=await import(pathToFileURL(native).href);
    observer=module.createPiWorkObserver({store:{append(){}},freshSessionsSince:"1970-01-01T00:00:00.000Z",diagnose(){throw Error("observer-diagnostic");}});
  }
  const fixtureExtension=pi=>{
    pi.on("session_start",(_event,ctx)=>{source={version:1,hostSessionId:ctx.sessionManager.getSessionId(),observerEpoch:"fixture-epoch",seq:0,scope:"session-recent-observations",coverage:"not-observed",observations:[],omitted:0,authorization:"none",readOnly:true,executable:false};});
    pi.events.on(WORK_QUERY,q=>{queryReads++; if(q.hostSessionId===source?.hostSessionId)pi.events.emit(WORK_REPLY+q.requestId,{version:1,requestId:q.requestId,snapshot:source});});
  };
  host=await createHost(root,"work",{bridge:registerBridge,extensions:[observer?observer.extension:fixtureExtension],...(socket?{}:{transport:()=>({start(){},close(){},reply(){},publish(r){records.push(structuredClone(r));if(records.length>100)records.shift();},dropped:0})})});
  await until(()=>records.some(r=>r.snapshot?.governance?.coverage==="not-observed"));
  const binding={workRef:{owner:"example/native-owner",kind:"task",key:"existing-work"},stageId:"subagent-output-available",runId:"existing-run",sessionId:host.session.sessionId,revision:0};
  const original={binding,resultRef:"existing-result",decision:"deliverable",outcome:"accepted",reasonCode:"owner_acceptance_confirmed",authorization:"none",readOnly:true};
  if(observer){
    host.api.events.emit("pi-vista:owner-result",{hostSessionId:host.session.sessionId,reference:{binding,resultRef:"existing-result"},readOwner(){ownerReads++; const time=Date.now(),observedAt=new Date(time).toISOString(),freshUntil=new Date(time+30000).toISOString(); return {binding,sourceKind:"artifact",sourceRef:"original-artifact",disposition:"accepted",observedAt,freshUntil,requiredEffects:[],requiredEvidence:[{evidenceId:"artifact-readback",kind:"readback",sourceRef:"original-artifact",claims:["artifact-available"]}],evidence:[{binding,record:{evidence_id:"artifact-readback",run_id:binding.runId,kind:"readback",state:"validated",source_ref:"original-artifact",claims:["artifact-available"],observed_at:observedAt,fresh_until:freshUntil,counterevidence_refs:[],redaction_profile:"metadata-only"}}]};}});
    await observer.drain();
  }else{
    source={...source,seq:1,coverage:"observed",observations:[{seq:1,observedAt:Date.now(),kind:"result",observation:original}]};
    host.api.events.emit(WORK_CHANGED,{version:1,snapshot:source});
  }
  await until(()=>records.some(r=>r.snapshot?.governance?.results?.length));
  const observation=records.filter(r=>r.snapshot?.governance?.results?.length).at(-1).snapshot.governance;
  assert.deepEqual(observation.results[0].observation,original); assert.equal(observation.source,"pi.vista");
  const time=observation.results[0].observedAt;
  // Directly exercise the owner export, not an acceptance reader. Repeat reads
  // must retain original observation timestamps and cannot call readOwner again.
  let reply; const id="fixture-memory-read";
  const off=host.api.events.on(WORK_REPLY+id,value=>{reply=value;});
  host.api.events.emit(WORK_QUERY,{version:1,requestId:id,hostSessionId:host.session.sessionId});
  await until(()=>reply!==undefined); off();
  assert.equal(reply.snapshot.observations[0].observedAt,time);
  if (socket) {
    let refreshObserved = false; const offQuery = host.api.events.on(WORK_QUERY, () => { refreshObserved = true; });
    const identity = records.find(r => r.snapshot?.governance?.results?.length).identity;
    server.stdin.write(JSON.stringify({version:1,kind:"query",identity,requestId:"fixture-work-refresh",query:"work.refresh"}) + "\n");
    await until(() => refreshObserved); offQuery();
  }
  assert.equal(ownerReads,observer?1:0); assert.equal(host.faux.state.callCount,0); assert.deepEqual(host.errors,[]);
  console.log(JSON.stringify({ok:true,nativeSDK:true,realSwiftUDS:socket,source:observer?"explicit-vista-owner":"frozen-contract-fixture",ownerReads,queryReads,workBindingPreserved:true,observationTimeUnchanged:true,extraOwnerReads:0,realProviderCalls:0}));
} finally {
  if(host)await host.close();
  if(server&&server.exitCode===null){const exited=new Promise(resolve=>server.once("exit",resolve)),timer=setTimeout(()=>server.kill(),1000).unref();server.stdin.end();await exited;clearTimeout(timer);}
  await rm(root,{recursive:true,force:true});
}
