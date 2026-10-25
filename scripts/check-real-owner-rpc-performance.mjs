import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";
import { createHost, bindFixturePeerImports, sdkRoot } from "./native-host.mjs";
import { OwnerRPC } from "../packages/desk-bridge/src/owners.ts";
if(!process.env.PI_DESK_SUBAGENTS)throw Error("explicit fixed owner package required");
await mkdir("tmp/real-owner-perf",{recursive:true});const root=await mkdtemp(resolve("tmp/real-owner-perf/case-"));
process.env.PI_CODING_AGENT_DIR=join(root,"A/agent");process.env.PI_SUBAGENTS_TEMP_ROOT=join(root,"runtime");
await mkdir(join(root,"A/agent/extensions/subagent"),{recursive:true});await writeFile(join(root,"A/agent/extensions/subagent/config.json"),JSON.stringify({intercomBridge:{mode:"off"}}));
bindFixturePeerImports();const {default:subagents}=await import(pathToFileURL(join(process.env.PI_DESK_SUBAGENTS,"index.js")).href);
const h=await createHost(root,"A",{extensions:[subagents]});const rpc=new OwnerRPC(h.api.events,"subagents:rpc:v1",10000);
try{
 const sm=h.session.sessionManager;
 for(let i=0;i<10000;i++)sm.appendMessage({role:"assistant",content:[],api:"openai-completions",provider:"fixture-gpt",model:"gpt-6.1-sol",stopReason:"stop",timestamp:Date.now()-1000,usage:{input:100,output:10,cacheRead:1000,cacheWrite:0,totalTokens:1110,cost:{input:0,output:0,cacheRead:0,cacheWrite:0,total:0}}});
 for(let i=0;i<128;i++)sm.appendMessage({role:"toolResult",toolCallId:"synthetic-"+i,toolName:"subagent",content:[],isError:false,timestamp:Date.now(),details:{mode:"single",results:[{agent:"fixture",runId:"synthetic-run-"+i,usage:{input:10,output:5,cacheRead:0,cacheWrite:0,cost:0,turns:1}}]}});
 const measurements=[];
 for(let i=0;i<8;i++){const start=performance.now();const result=rpc.call("cost");const synchronousMs=performance.now()-start;const report=await result;measurements.push({synchronousMs,totalMs:performance.now()-start});assert.equal(report.parent.turns,10000);assert.ok(report.children.length>=128);}
 const result={ok:true,synthetic:true,sdkRoot,ownerPackage:process.env.PI_DESK_SUBAGENTS,branchEntries:10128,reportedChildren:128,measurements,realProviderCalls:0,scope:"actual fixed owner RPC cost with metadata-only in-memory synthetic branch; no original session file read"};await writeFile(join(root,"result.json"),JSON.stringify(result,null,2),{mode:0o600});console.log(JSON.stringify(result));
}finally{rpc.close();await h.close();}
