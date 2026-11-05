import test from "node:test";
import assert from "node:assert/strict";
import type { InputNotice } from "../src/protocol.ts";
import { QuestionObserver } from "../src/question-observer.ts";
const workRef={owner:"example/product",kind:"change",key:"existing-change"};
const event=(overrides:object={})=>({version:1,source:"ask_user_question",sessionId:"host-a",toolCallId:"call-a/1",epoch:"owner-a",seq:1,phase:"opened",observedAt:1000,workAssociation:"declared",workRef,stageId:"design-choice",closeReason:null,...overrides});
const legacy=(phase:string,id="call-a/1")=>({version:1,source:"ask_user_question",id,phase});
test("legacy and linked opened share one input, one stable time, no content or extra authority",()=>{
 const inputs=new Map<string,InputNotice>(), observer=new QuestionObserver("host-a",inputs,()=>900);
 assert.ok(observer.legacy(legacy("start"))); const id=[...inputs.keys()][0];
 assert.ok(observer.observe(event())); assert.equal(inputs.size,1); assert.equal([...inputs.keys()][0],id); assert.equal(inputs.get(id)?.startedAt,900);
 assert.equal(inputs.get(id)?.question?.binding,"declared"); assert.deepEqual(inputs.get(id)?.question?.workRef,workRef);
 assert.equal(observer.legacy(legacy("start")),false); assert.equal(observer.observe(event()),false);
 assert.ok(!id.includes("call-a/1")); assert.equal(inputs.get(id)?.question?.sequence,1);
});
test("no work binding or unsafe declarations do not break the actual input lifecycle",()=>{
 const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
 o.observe(event({workAssociation:"unbound",workRef:null,stageId:null})); assert.equal([...inputs.values()][0].question?.binding,"unbound");
 o.observe(event({toolCallId:"call-b",seq:2,workRef:{...workRef,key:"/private/secret"}}));
 assert.equal(inputs.size,2); assert.equal([...inputs.values()][1].question?.binding,"unavailable");
 const bad={...event({toolCallId:"call-c",seq:3}),get workRef(){throw Error("must not invoke caller getter")}};
 assert.ok(o.observe(bad)); assert.equal([...inputs.values()][2].question?.binding,"unavailable");
 o.legacy(legacy("end","call-c"));
 assert.ok(!JSON.stringify([...inputs.values()]).includes("/private"));
 o.observe(event({toolCallId:"call-b",seq:4,phase:"closed",closeReason:"error"})); assert.equal(inputs.size,1);
});
test("answer receipt stops waiting but does not set work completion or permission",()=>{
 const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
 o.observe(event()); assert.equal(inputs.size,1);
 o.observe(event({seq:2,phase:"answer-received"})); assert.equal(inputs.size,0);
 assert.equal(o.legacy(legacy("start")),false,"late v1 start cannot reopen an observed terminal input");
 o.observe(event({seq:3,phase:"closed",closeReason:"answered"})); assert.equal(inputs.size,0);
 for(const closeReason of ["declined","aborted","error","chat","empty"]){ const v=new QuestionObserver("host-a",inputs,()=>1);v.observe(event());v.observe(event({seq:2,phase:"closed",closeReason}));assert.equal(inputs.size,0); }
});
test("wrong host and retired work epochs cannot close the current linked request",()=>{
 const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
 assert.equal(o.observe(event({sessionId:"another-host"})),false);
 o.observe(event()); o.observe(event({epoch:"owner-b",seq:1})); assert.equal(inputs.size,1);
 assert.equal(o.observe(event({phase:"closed",seq:999,closeReason:"answered"})),false);
 assert.equal(inputs.size,1);
 o.observe(event({epoch:"owner-b",seq:2,phase:"closed",closeReason:"aborted"})); assert.equal(inputs.size,0);
});
test("legacy end remains usable when optional work metadata is unavailable",()=>{
 const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
 o.legacy(legacy("start")); o.observe(event()); assert.equal(inputs.size,1);
 assert.equal(o.observe(event({seq:2,phase:"closed",closeReason:"malformed"})),false);
 assert.ok(o.legacy(legacy("end"))); assert.equal(inputs.size,0);
});
test("higher-sequence native opened observations are not rejected by a Desk task state machine",()=>{
 const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
 o.observe(event());o.observe(event({seq:2,phase:"closed",closeReason:"declined"}));
 assert.equal(inputs.size,0);assert.ok(o.observe(event({seq:3})));assert.equal(inputs.size,1);
});
test("owner native call IDs preserve compound provider identity without exposing it",()=>{
 for (const toolCallId of ["call-a|provider:ref/1/22", "c".repeat(500)+"/1"]) {
  const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
  o.legacy(legacy("start",toolCallId)); o.observe(event({toolCallId})); assert.equal(inputs.size,1);
  assert.equal([...inputs.keys()][0].length,73); o.legacy(legacy("end",toolCallId)); assert.equal(inputs.size,0);
 }
 for (const toolCallId of ["..", "call/0", "C:/1", "call/file", "c".repeat(513)]) {
  const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
  assert.equal(o.observe(event({toolCallId})),false); assert.equal(inputs.size,0);
 }
});
test("opaque v1 works on its own and unobserved terminals never manufacture a prompt",()=>{
 const inputs=new Map<string,InputNotice>(), o=new QuestionObserver("host-a",inputs,()=>1);
 assert.equal(o.observe(event({phase:"closed",seq:2,closeReason:"answered"})),false); assert.equal(inputs.size,0);
 o.legacy(legacy("start")); o.legacy(legacy("end")); assert.equal(inputs.size,0);
 let touched=0; o.observe({...event(),get question(){touched++;throw Error()},get answer(){touched++;throw Error()}});assert.equal(touched,0);
 assert.equal(inputs.size,1);o.close();
});
