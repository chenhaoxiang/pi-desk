import assert from "node:assert/strict";
import { mkdir,mkdtemp,rm,readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve,join } from "node:path";
import { spawn } from "node:child_process";
import { createHost,ai,until } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
await mkdir("tmp",{recursive:true});
const root=await mkdtemp(resolve("tmp/nsr-")),socket=process.argv.includes("--socket");
const records=[];let ready=false,carry="",server;
if(socket){
  await mkdir(join(root,"run"),{mode:0o700});
  process.env.PI_DESK_SOCKET=join(root,"run/desk.sock");process.env.PI_DESK_PEER_CHECK=resolve(".build/debug/PiDeskPeerCheck");
  server=spawn(resolve(".build/debug/PiDeskTransportTests"),["--serve",process.env.PI_DESK_SOCKET],{stdio:["pipe","pipe","inherit"]});
  server.stdout.on("data",b=>{carry+=String(b);while(carry.includes("\n")){let n=carry.indexOf("\n"),v=JSON.parse(carry.slice(0,n));carry=carry.slice(n+1);if(v.event==="socket-ready")ready=true;if(v.event==="record")records.push(v.record);}});
}
let host;
try{
  if(socket)await until(()=>ready);
  host=await createHost(root,"metadata",{bridge:registerBridge,...(socket?{}:{transport:()=>({start(){},close(){},reply(){},publish(r){records.push(structuredClone(r));},dropped:0})})});
  host.faux.setResponses([ai.fauxAssistantMessage("PRIVATE_SYNTHETIC_ASSISTANT_TEXT")]);
  await host.session.prompt("PRIVATE_SYNTHETIC_USER_TEXT");
  const manager=host.session.sessionManager;
  const first=manager.getEntries().find(e=>e.type==="message");
  manager.appendCompaction("PRIVATE_SYNTHETIC_SUMMARY",first.id,9000);
  await until(()=>records.some(r=>r.snapshot));
  const expected=manager.getEntries().filter(e=>e.type==="compaction").length;
  const calls=host.faux.state.callCount,oldEpoch=records.at(-1).identity.runtimeEpoch;
  await host.session.reload(); // only this owned isolated idle test session
  await until(()=>records.some(r=>r.identity.runtimeEpoch!==oldEpoch&&r.snapshot?.nativeSessionMeta?.coverage==="observed"));
  const projected=records.filter(r=>r.identity.runtimeEpoch!==oldEpoch&&r.snapshot?.nativeSessionMeta?.coverage==="observed").at(-1);
  assert.equal(projected.snapshot.nativeSessionMeta.compactions,expected);
  assert.equal(projected.snapshot.activity,undefined,"existing records appear on startup without inventing a new event/turn end");
  assert(projected.snapshot.nativeSessionMeta.lastActivityAt>0);
  assert.equal(host.faux.state.callCount,calls,"startup native metadata never launches a model");
  assert(!JSON.stringify(projected).includes("PRIVATE_SYNTHETIC"));assert.deepEqual(host.errors,[]);
  console.log(JSON.stringify({ok:true,nativeSdk:true,realSwiftUDS:socket,publicCurrentMemory:true,originalCompactionCount:expected,startupActivityWithoutNewTurn:true,rawActivityNotFabricated:true,privateTextNotProjected:true,metadataExtraModelCalls:0,realProviderCalls:0,activeBusinessReloads:0}));
}finally{
  if(host){
    await host.close();
    // Reload owns two asynchronous writers for the same native session. The
    // shared host helper may first find the old closed recorder; drain BOTH
    // exact runtime receipts before deleting this fixture's private directory.
    const epochs=new Set(records.map(r=>r.identity.runtimeEpoch));
    await until(async()=>{
      for(const epoch of epochs){
        const id=createHash("sha256").update(epoch).digest("hex");
        const state=await readFile(join(root,"usage-v1/recorders",id+".json"),"utf8").then(JSON.parse,()=>null);
        if(!state||state.closed!==true||state.pending!==0)return false;
      }
      return true;
    });
  }
  if(server&&server.exitCode===null){const exit=new Promise(r=>server.once("exit",r));const safety=setTimeout(()=>server.kill(),1000).unref();server.stdin.end();await exit;clearTimeout(safety);}
  await rm(root,{recursive:true,force:true});
}
