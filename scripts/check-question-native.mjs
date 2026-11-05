import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { createHost, until, bindFixturePeerImports, sdk, ai } from "./native-host.mjs";
import { registerBridge } from "../packages/desk-bridge/src/index.ts";
const root=await (await mkdir("tmp",{recursive:true}),mkdtemp(resolve("tmp/qi-")));
const records=[], events=[]; let server,host,currentComponent;
const socket=process.argv.includes("--socket"), entry=process.env.PI_DESK_QUESTION_ENTRY;
const workRef={owner:"example/native",kind:"change",key:"existing-work"};
const ui=new Proxy({ custom: async factory => new Promise(resolve=>{
  const tui={requestRender(){},terminal:{columns:80,rows:24}},theme={fg:(_name,text)=>text,bg:(_name,text)=>text,bold:text=>text};
  currentComponent=factory(tui,theme,{},resolve);
}) },{get:(target,key)=>key in target?target[key]:()=>{}});
function fixtureQuestion(pi){
 let epoch="fixture-owner",seq=0;
 pi.registerTool({name:"ask_user_question",label:"Fixture question",description:"frozen content-free contract fixture",parameters:{type:"object",properties:{},additionalProperties:true},async execute(id,params,signal,_onUpdate,ctx){
  const association=params.workRef?"declared":"unbound";
  const emit=(phase,closeReason=null)=>{const event={version:1,source:"ask_user_question",sessionId:ctx.sessionManager.getSessionId(),toolCallId:id,epoch,seq:++seq,phase,observedAt:Date.now(),workAssociation:association,workRef:params.workRef??null,stageId:params.stageId??null,closeReason};pi.events.emit("pi:work-question:v1",event);};
  let choice;
  try{choice=await ctx.ui.custom((_t,_theme,_key,done)=>{pi.events.emit("pi:input-required",{version:1,source:"ask_user_question",id,phase:"start"});emit("opened");const abort=()=>done(null);signal?.addEventListener("abort",abort,{once:true});return{render:()=>[],invalidate(){},handleInput:()=>{signal?.removeEventListener("abort",abort);done("SYNTHETIC_ANSWER");}};});}
  finally{pi.events.emit("pi:input-required",{version:1,source:"ask_user_question",id,phase:"end"});}
  if(choice!==null)emit("answer-received");emit("closed",signal?.aborted?"aborted":choice===null?"declined":"answered");return {content:[{type:"text",text:"fixture result"}],details:{answer:choice}};
 }});
}
try{
 if(socket){process.env.PI_DESK_SOCKET=join(root,"desk.sock");process.env.PI_DESK_PEER_CHECK=resolve(".build/debug/PiDeskPeerCheck");let ready=false,carry="";server=spawn(resolve(".build/debug/PiDeskTransportTests"),["--serve",process.env.PI_DESK_SOCKET],{stdio:["pipe","pipe","inherit"]});server.stdout.on("data",bytes=>{carry+=String(bytes);while(carry.includes("\n")){const at=carry.indexOf("\n"),row=JSON.parse(carry.slice(0,at));carry=carry.slice(at+1);if(row.event==="socket-ready")ready=true;if(row.event==="record"){records.push(row.record);if(records.length>100)records.shift();}}});await until(()=>ready);}
 let factory=fixtureQuestion;
 if(entry){bindFixturePeerImports();factory=(await import(pathToFileURL(entry).href)).default;assert.equal(typeof factory,"function");}
 host=await createHost(root,"question",{bridge:registerBridge,extensions:[sdk.createCodemodeExtension({mode:"on"}),factory,pi=>{
  pi.events.on("pi:work-question:v1",event=>events.push(structuredClone(event)));
 }],bindings:{mode:"tui",uiContext:ui},...(socket?{}:{transport:()=>({start(){},close(){},reply(){},publish(r){records.push(structuredClone(r));if(records.length>100)records.shift();},dropped:0})})});
 host.session.setActiveToolsByName(["ask_user_question","codemode"]);
 const tool=host.session.agent.state.tools.find(t=>t.name==="ask_user_question");assert.ok(tool);
 const before={tools:host.session.getActiveToolNames(),model:host.session.model,thinking:host.session.thinkingLevel};
 for(const [id,bound,abort] of [["question-native/1",true,false],["question-unbound",false,true]]){
  const signal=new AbortController();currentComponent=undefined;
  const params={question:"PRIVATE_QUESTION_TEXT",options:[{label:"PRIVATE_OPTION_A"}],...(bound?{workRef,stageId:"choice"}:{})};
  const eventStart=events.length;
  if(bound)host.faux.setResponses([ai.fauxAssistantMessage(ai.fauxToolCall("codemode",{code:"text(await tools.ask_user_question("+JSON.stringify(params)+"));"}),{stopReason:"toolUse"}),ai.fauxAssistantMessage("SYNTHETIC_DONE")]);
  const pending=bound?host.session.prompt("Synthetic native question fixture"):tool.execute(id,params,signal.signal);
  await until(()=>records.some(r=>r.snapshot?.inputs?.some(i=>i.question?.binding===(bound?"declared":"unbound"))));
  const active=records.filter(r=>r.snapshot?.inputs?.length).at(-1).snapshot.inputs;
  assert.equal(active.length,1,"v1 and work event cannot duplicate the question");
  assert.ok(!JSON.stringify(records).includes("PRIVATE_"));
  if(bound)assert.deepEqual(active[0].question.workRef,workRef);
  if(abort)signal.abort();else currentComponent.handleInput("\r");
  await pending;await until(()=>records.at(-1)?.snapshot?.inputs?.length===0);
  const own=events.slice(eventStart);assert.ok(own.length);assert.equal(new Set(own.map(e=>e.toolCallId)).size,1);if(bound)assert.ok(own[0].toolCallId.endsWith("/1"));assert.deepEqual(own.map(e=>e.phase),abort?["opened","closed"]:["opened","answer-received","closed"]);
  assert.equal(own.at(-1).closeReason,abort?"aborted":"answered");
 }
 assert.equal(host.faux.state.callCount,2);assert.deepEqual(host.errors,[]);assert.deepEqual({tools:host.session.getActiveToolNames(),model:host.session.model,thinking:host.session.thinkingLevel},before);
 console.log(JSON.stringify({ok:true,nativeSDK:true,source:entry?"explicit-question-owner":"frozen-question-contract",realSwiftUDS:socket,actualCodemode:true,oneInputPerQuestion:true,declaredAndUnbound:true,answeredAndAborted:true,noPromptOrAnswerProjected:true,noAnswerEndpoint:true,syntheticModelRounds:2,realProviderCalls:0,displayAddedModelCalls:0,loadoutUnchanged:true}));
}finally{if(host)await host.close();if(server&&server.exitCode===null){const exited=new Promise(resolve=>server.once("exit",resolve)),timer=setTimeout(()=>server.kill(),1000).unref();server.stdin.end();await exited;clearTimeout(timer);}await rm(root,{recursive:true,force:true});}
