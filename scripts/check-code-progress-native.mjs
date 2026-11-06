import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile, rm } from "node:fs/promises";
import { resolve, join, dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { createHost, ai, until } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
import { WORK_QUERY, WORK_REPLY, WORK_CHANGED } from "../packages/desk-bridge/src/governance-client.ts";

// Explicit original producer source is optional. Even that path uses synthetic
// GitHub/Gate originals through its actual reader; this is not a live PR or W3.
const native = process.env.PI_VISTA_WORK_OBSERVER, oldClient = process.env.PI_DESK_LEGACY_GOVERNANCE;
const socket = process.argv.includes("--socket"), entry = process.env.PI_DESK_PROGRESS_BRIDGE;
const bridge = entry ? (await import(pathToFileURL(entry).href)).registerBridge : registerBridge;
await mkdir("tmp", {recursive:true});
const root = await mkdtemp(resolve("tmp/cp-")), contractFile = join(root,"private-contract.json"), gateFile = join(root,"private-gate.json");
const records = [], stages = [], hosts = []; let server, observer, legacy, source, contract, originals, phase = 0, ownerReads = 0, githubReads = 0, gateReads = 0, queryCount = 0;
const head = "a".repeat(40), merge = "b".repeat(40), reviewHash = "c".repeat(64), stamp = Date.now()-5000;
const current = host => records.filter(r=>r.identity.nativeSessionId===host.session.sessionId && r.snapshot).at(-1)?.snapshot;
const fixtureExtension = pi => {
  pi.on("session_start",(_e,ctx)=>{ source={version:1,hostSessionId:ctx.sessionManager.getSessionId(),observerEpoch:"fixture-progress-epoch",seq:0,scope:"session-recent-observations",coverage:"not-observed",observations:[],omitted:0,authorization:"none",readOnly:true,executable:false,codeProgress:{version:1,source:"explicit-code-owner",seq:0,coverage:"not-observed",observations:[],omitted:0}}; });
  pi.events.on(WORK_QUERY,q=>{if(q.hostSessionId===source.hostSessionId)pi.events.emit(WORK_REPLY+q.requestId,{version:1,requestId:q.requestId,snapshot:source});});
  pi.registerTool({name:"vista_code_observe",label:"Frozen code owner",description:"Synthetic frozen contract",exposure:"codemode",parameters:{type:"object",properties:{contractFile:{type:"string"}},required:["contractFile"],additionalProperties:false},async execute(){
    ownerReads++;
    const triples=[["head-checks","required_checks_pending","wait_required_checks"],["source-delivery","none","inspect_result"],["unknown","source_binding_mismatch","inspect_binding"]];
    if(phase<3){
      const [p,w,n]=triples[phase], next=source.codeProgress.seq+1;
      source={...source,codeProgress:{...source.codeProgress,seq:next,coverage:"observed",observations:[...source.codeProgress.observations,{seq:next,binding:contract.binding,repository:contract.repository,pullRequest:contract.pullRequest,observedAt:Date.now(),phase:p,waitReason:w,nextAction:n,authorization:"none",readOnly:true,executable:false}]}};
      if(phase===1)source={...source,seq:1,coverage:"observed",observations:[{seq:1,observedAt:Date.now(),kind:"result",observation:{binding:contract.binding,resultRef:"github-pr-7",decision:"deliverable",outcome:"accepted",reasonCode:"owner_acceptance_confirmed",authorization:"none",readOnly:true}}]};
    }else source={...source,codeProgress:{...source.codeProgress,seq:source.codeProgress.seq+1,coverage:"unavailable"}};
    pi.events.emit(WORK_CHANGED,{version:1,snapshot:source});
    return {content:[{type:"text",text:"SYNTHETIC_OWNER_DONE"}],details:{available:phase<3}};
  }});
};
try {
  let nativeModule;
  if(native){
    nativeModule=await import(pathToFileURL(native).href);
    const {readCodeStage}=await import(pathToFileURL(join(dirname(native),"pi-code-stage-reader.mjs")).href);
    observer=nativeModule.createPiWorkObserver({freshSessionsSince:"1970-01-01T00:00:00.000Z",store:{append(){}},diagnose(){},codeOwner:{readStage:async(value,options)=>{
      ownerReads++;
      return readCodeStage(value,{...options,readGitHub:async kind=>{githubReads++;return structuredClone(originals[kind]);},readGate:async file=>{assert.equal(file,gateFile);gateReads++;return readFile(file);}});
    }}});
  }
  if(socket){
    process.env.PI_DESK_SOCKET=join(root,"desk.sock");process.env.PI_DESK_PEER_CHECK=resolve(".build/debug/PiDeskPeerCheck");
    let ready=false,carry="";server=spawn(resolve(".build/debug/PiDeskTransportTests"),["--serve",process.env.PI_DESK_SOCKET],{stdio:["pipe","pipe","inherit"]});
    server.stdout.on("data",bytes=>{carry+=String(bytes);while(carry.includes("\n")){const i=carry.indexOf("\n"),e=JSON.parse(carry.slice(0,i));carry=carry.slice(i+1);if(e.event==="socket-ready")ready=true;if(e.event==="record"){records.push(e.record);if(records.length>512)records.shift();}}});await until(()=>ready);
  }
  const driver=pi=>{
    pi.events.on(WORK_QUERY,()=>{queryCount++;});
    pi.registerTool({name:"exercise_code",label:"Synthetic observation call",description:"Exercise existing code observer only",parameters:{type:"object",properties:{},additionalProperties:false},async execute(_id,_input,_signal,_update,ctx){
      if(phase===0){const before=ownerReads;const invalid=await ctx.executeTool("vista_code_observe",{contractFile,accepted:true});assert.equal(invalid.isError,true);assert.equal(ownerReads,before,"invalid accepted flag rejected before reader IO");}
      const outcome=await ctx.executeTool("vista_code_observe",{contractFile});assert.notEqual(outcome.isError,true);
      return {content:[{type:"text",text:"SYNTHETIC_FINISHED"}],details:{fixture:true}};
    }});
  };
  const host=await createHost(root,"code-work",{bridge,extensions:[observer?observer.extension:fixtureExtension,driver],...(socket?{}:{transport:()=>({start(){},close(){},reply(){},publish(r){records.push(structuredClone(r));if(records.length>512)records.shift();},dropped:0})})});hosts.push(host);
  await until(()=>current(host)?.codeProgress?.coverage==="not-observed");
  if(oldClient){const {GovernanceClient}=await import(pathToFileURL(oldClient).href);legacy=new GovernanceClient(host.api.events,host.session.sessionId,()=>{});legacy.start();await until(()=>legacy.read().coverage==="not-observed");}
  contract={binding:{workRef:{owner:"example/engineering",kind:"change",key:"existing-work"},stageId:"source-shared-delivery",runId:"sdk-original",sessionId:host.session.sessionId,revision:0,headSha:head},repository:"example/engineering",pullRequest:7,baseRef:"main",headChecks:[{name:"tests",appId:10},{name:"review",appId:20,reviewHash}],mergeWorkflows:["main checks"],gateReportFile:gateFile};
  originals={repository:{full_name:contract.repository,private:false,visibility:"public"},pr:{number:7,state:"open",draft:false,merged:false,merged_at:null,merge_commit_sha:null,head:{sha:head},base:{ref:"main",repo:{full_name:contract.repository}}},checks:{total_count:2,check_runs:contract.headChecks.map((r,i)=>({id:i+1,name:r.name,app:{id:r.appId},head_sha:head,status:"in_progress",conclusion:null,output:{summary:r.reviewHash??""}}))},workflows:{total_count:1,workflow_runs:[{id:30,name:"main checks",head_sha:merge,event:"push",head_branch:"main",repository:{full_name:contract.repository},status:"completed",conclusion:"success"}]},ancestry:{status:"ahead",base_commit:{sha:merge}}};
  const gate={result_scope:"gate-evaluation",pass:true,verdict:"PASS",execution_exit_code:0,execution_merge_sha:merge,gate_observation:{gate_started_at:new Date(stamp-2000).toISOString(),gate_finished_at:new Date(stamp-1000).toISOString()},evidence_readiness:{binding:{repository:contract.repository,pr:7,head_sha:head,base_ref:"main",merge_sha:merge}},execution_observations_schema:"ai-gate-observations/1",execution_observations:["gate-evaluate","actual-merge","post-merge-ci"].map(action=>({action,result:"ok",reason_code:action==="actual-merge"?"merge-observed":"ok",head_sha:head,source_sha:head}))};
  await writeFile(contractFile,JSON.stringify(contract),{mode:0o600});await writeFile(gateFile,JSON.stringify(gate),{mode:0o600});
  let accepted, loadout={model:host.session.model,thinking:host.session.thinkingLevel,tools:host.session.getActiveToolNames()};
  for(phase=0;phase<4;phase++){
    if(phase===1){Object.assign(originals.pr,{state:"closed",merged:true,merged_at:new Date(stamp).toISOString(),merge_commit_sha:merge});for(const r of originals.checks.check_runs)Object.assign(r,{status:"completed",conclusion:"success"});}
    if(phase===2)originals.pr.head.sha="d".repeat(40);
    if(phase===3){originals.repository.private=true;originals.repository.visibility="private";}
    const reads=ownerReads, gets=githubReads;
    host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("exercise_code",{}),{stopReason:"toolUse"}),ai.fauxAssistantMessage("SYNTHETIC_COMPLETE")]);
    await host.session.prompt("Synthetic explicit original observation");await host.session.waitForIdle();
    assert.equal(ownerReads,reads+1);assert.equal(githubReads-gets,native?[5,8,2,1][phase]:0);
    await until(()=>current(host)?.codeProgress?.seq===phase+1);
    const snapshot=current(host), progress=snapshot.codeProgress;
    if(phase===0){assert.equal(progress.observations[0].waitReason,"required_checks_pending");assert.equal(snapshot.governance.results.length,0);}
    if(phase===1){accepted=structuredClone(snapshot.governance);assert.equal(accepted.results[0].observation.decision,"deliverable");assert.equal(progress.observations.at(-1).phase,"source-delivery");}
    if(phase>=2)assert.deepEqual(snapshot.governance,accepted,"progress-only unknown/unavailable cannot change original acceptance time/seq/result");
    if(phase===2)assert.equal(progress.observations.at(-1).waitReason,"source_binding_mismatch");
    if(phase===3){assert.equal(progress.coverage,"unavailable");assert.equal(progress.stale,true);assert.equal(progress.observations.length,3);}
    assert.deepEqual(snapshot.inputs,[]);if(legacy)assert.deepEqual(legacy.read(),snapshot.governance);
    const frozenProgress=structuredClone(progress),queryBefore=queryCount,readBefore=ownerReads,getBefore=githubReads;
    if(socket){server.stdin.write(JSON.stringify({version:1,kind:"query",identity:snapshot.identity,requestId:"memory-refresh-"+phase,query:"work.refresh"})+"\n");await until(()=>queryCount>queryBefore);}
    else {const id="fixture-read-"+phase;host.api.events.emit(WORK_QUERY,{version:1,requestId:id,hostSessionId:host.session.sessionId});}
    assert.equal(ownerReads,readBefore);assert.equal(githubReads,getBefore);assert.deepEqual(current(host).codeProgress,frozenProgress);
    stages.push({phase,record:{version:1,kind:"hello",identity:snapshot.identity,snapshot}});
  }
  assert.deepEqual(host.errors,[]);assert.equal(host.faux.state.callCount,8);assert.deepEqual({model:host.session.model,thinking:host.session.thinkingLevel,tools:host.session.getActiveToolNames()},loadout);
  for(const value of [contractFile,gateFile,"accepted:true"])assert.ok(!JSON.stringify(records).includes(value));
  const report={ok:true,nativeSDK:true,realSwiftUDS:socket,source:native?"actual-producer-with-synthetic-GitHub-and-Gate-originals":"frozen-contract-fixture",originalReaderCalls:ownerReads,fixtureGitHubReads:githubReads,fixtureGateReads:gateReads,explicitRefreshes:4,refreshAdditionalReads:0,oldResultTimeAndSequenceUnchanged:true,unavailableRetainsStaleRows:true,actualLegacyClient:!!legacy,syntheticModelRounds:8,realProviderCalls:0,notRealEngineeringOrW3:true};
  if(process.env.PI_DESK_PROGRESS_EVIDENCE)await writeFile(process.env.PI_DESK_PROGRESS_EVIDENCE,JSON.stringify({report,stages},null,2),{mode:0o600});
  console.log(JSON.stringify(report));
}finally{
  legacy?.close();for(const host of hosts)await host.close();
  if(server&&server.exitCode===null){const done=new Promise(r=>server.once("exit",r)),timer=setTimeout(()=>server.kill(),1000).unref();server.stdin.end();await done;clearTimeout(timer);}
  await rm(root,{recursive:true,force:true});
}
