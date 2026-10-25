import assert from "node:assert/strict";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readdir, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { once } from "node:events";
if (process.argv.includes("--crash-child")) {
  const root = process.argv.at(-1);
  assert.ok(root.startsWith(resolve("tmp/publish-crash") + "/"));
  const require = createRequire(import.meta.url), fs = require("node:fs/promises"), original = fs.link;
  fs.link = async (...args) => { const value = await original(...args); process.kill(process.pid,"SIGKILL"); return value; };
  syncBuiltinESMExports();
  const { UsageWriter, usageEntry } = await import("../packages/desk-bridge/src/usage-store.ts");
  const identity={localHostId:"fixture",nativeSessionId:"crash-gpt",runtimeEpoch:"crash-epoch"};
  const entry=usageEntry(identity,"receipt-crash",{role:"assistant",provider:"fixture-gpt",model:"gpt-6.1-sol",stopReason:"stop",timestamp:Date.now()-1000,usage:{input:11,output:3,cacheRead:7,cacheWrite:0}},Date.now());
  const writer=new UsageWriter(identity,{root});writer.enqueue(entry);await writer.flush();throw Error("must crash after actual production hard-link publish");
}
await mkdir("tmp/publish-crash",{recursive:true});const root=await mkdtemp(resolve("tmp/publish-crash/case-"));
const child=spawn(process.execPath,["--import","tsx",resolve("scripts/check-publish-crash.mjs"),"--crash-child",root],{stdio:["ignore","pipe","pipe"]});
let diagnostics="";child.stderr.on("data",b=>{diagnostics=(diagnostics+String(b)).slice(-3000);});
const [code,signal]=await once(child,"exit");assert.equal(signal,"SIGKILL",diagnostics);
let files=[];for(const shard of await readdir(join(root,"spool"))) for(const name of await readdir(join(root,"spool",shard))) files.push(join(root,"spool",shard,name));
const final=files.find(f=>/\/[a-f0-9]{64}\.json$/.test(f)),temp=files.find(f=>/\/\.usage-/.test(f));assert.ok(final&&temp);assert.equal((await stat(final)).nlink,2);assert.equal((await stat(final)).ino,(await stat(temp)).ino);
const result={ok:true,stage:"production-writer-link-then-crash",synthetic:true,root,final,temp,code,signal,linksBeforeRecovery:2};await writeFile(join(root,"result.json"),JSON.stringify(result,null,2),{mode:0o600});console.log(JSON.stringify(result));
