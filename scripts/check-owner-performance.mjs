import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { createHost, ai, sdkRoot, sdk, until } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
await mkdir("tmp/owner-performance", { recursive: true });
const root = await mkdtemp(resolve("tmp/owner-performance/case-"));
const artifact = join(root, "synthetic-artifact.json");
await writeFile(artifact, JSON.stringify(Array.from({length:50000},(_,i)=>({id:i,tokens:i%100,state:"complete"}))));
const withTUI = process.argv.includes("--tui");
if (withTUI) assert.ok(process.stdin.isTTY && process.env.PI_OFFLINE === "1");
async function check(enabled) {
  const records = []; let receive, costCalls=0, statusCalls=0, rpcSyncMs=[];
  const owner = pi => {
    pi.events.on("subagents:rpc:v1:request", r => {
      const start=performance.now(); let data={capabilities:{fleetStatus:{version:1},cost:{version:1}}};
      if(r.method==="cost") {costCalls++;const rows=JSON.parse(readFileSync(artifact,"utf8"));data={version:1,total:{input:rows.length,output:1,cacheRead:0,cacheWrite:0},children:[],unresolvedAsyncChildren:0};}
      if(r.method==="status"){statusCalls++;data={asyncSnapshot:{runs:[],omitted:{runs:0,children:0}},fleet:{entries:[],omitted:0}};}
      pi.events.emit("subagents:rpc:v1:reply:"+r.requestId,{version:1,requestId:r.requestId,success:true,data}); rpcSyncMs.push(performance.now()-start);
    });
    pi.events.on("schedule:rpc:v1:request",r=>pi.events.emit("schedule:rpc:v1:reply:"+r.requestId,{version:1,requestId:r.requestId,success:true,data:{capabilities:{managementActions:[]}}}));
  };
  const host=await createHost(root, enabled?"bridge":"baseline", {bridge:enabled?registerBridge:undefined,extensions:[owner],transport:(_h,recv)=>{receive=recv;return{start(){},close(){},publish:r=>records.push(r),reply:r=>records.push(r),dropped:0};}});
  let interactive, runtime;
  if (withTUI) { runtime = new sdk.AgentSessionRuntime(host.session,host.services,async()=>{throw Error("fixture-no-runtime-replacement");}); interactive = new sdk.InteractiveMode(runtime,{verbose:false,tuiMode:"inline"}); await interactive.init(); }
  const dispatch=[],turns=[]; const rss0=process.memoryUsage().rss;
  try{
    for(let i=0;i<30;i++){
      host.faux.setResponses([ai.fauxAssistantMessage("SYNTHETIC_PERF")]); const t=performance.now();await host.session.prompt("same synthetic task");turns.push(performance.now()-t);
      const d=performance.now();await host.session.extensionRunner.emit({type:"agent_settled",aborted:false});dispatch.push(performance.now()-d);
    }
    await new Promise(r=>setTimeout(r,100));
    assert.equal(costCalls,0,"turn boundaries must never synchronously collect owner cost/artifacts");assert.equal(statusCalls,0,"unfocused observation must not query owner status");
    if(enabled){receive({version:1,kind:"query",identity:records.at(-1).identity,requestId:"explicit-cost-interest",query:"usage.refresh"});await new Promise(r=>setTimeout(r,100));assert.equal(costCalls,1);}
    if(enabled) await until(()=>records.at(-1)?.snapshot?.usageRecorder?.pending===0,15000);
    const p=(a,n)=>a.sort((x,y)=>x-y)[Math.floor((a.length-1)*n)];
    const value={enabled,turns:turns.length,modelCalls:host.faux.state.callCount,dispatchP95ms:p(dispatch,.95),dispatchP99ms:p(dispatch,.99),turnMedianMs:p(turns,.5),rssDelta:process.memoryUsage().rss-rss0,costCalls,statusCalls,maxExplicitRPCSyncMs:Math.max(0,...rpcSyncMs),drops:records.at(-1)?.snapshot?.usageRecorder?.dropped??0,pending:records.at(-1)?.snapshot?.usageRecorder?.pending??0};
    assert.ok(value.dispatchP95ms<=1&&value.dispatchP99ms<=5);assert.equal(value.modelCalls,30);assert.deepEqual(host.errors,[]);return value;
  }finally{interactive?.stop();await host.close();if(runtime)await runtime.dispose();}
}
const baseline=await check(false),bridge=await check(true);const result={ok:true,synthetic:true,sdkRoot,baseline,bridge,realProviderCalls:0,addedModelCalls:bridge.modelCalls-baseline.modelCalls,addedConfirmations:0,artifactBytes:(await readFile(artifact)).length};
result.processHasPTY = !!process.stdin.isTTY; result.actualInteractiveMode = withTUI;
await writeFile(join(root,"result.json"),JSON.stringify(result,null,2),{mode:0o600});
if(process.env.PI_DESK_TUI_RESULT) await writeFile(process.env.PI_DESK_TUI_RESULT,JSON.stringify(result,null,2),{mode:0o600});
console.log(JSON.stringify(result));
if(withTUI)process.exit(0);
