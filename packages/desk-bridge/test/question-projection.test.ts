import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validQuestionWorkLink } from "../src/question-projection.ts";
import { validate } from "../src/protocol.ts";
const notice=JSON.parse(readFileSync(new URL("../../../Fixtures/question-link-v1.json",import.meta.url),"utf8"));
test("shared question attachment is optional, bounded, and explicit",()=>{
  const wire=JSON.parse(readFileSync(new URL("../../../Fixtures/wire-v1.json",import.meta.url),"utf8"));
  wire.snapshot.inputs=[notice]; validate(wire); assert.ok(validQuestionWorkLink(notice.question));
  wire.snapshot!.inputs=[{...notice,question:undefined}]; validate(wire);
  assert.equal(validQuestionWorkLink({...notice.question,binding:"unbound"}),false);
  assert.equal(validQuestionWorkLink({...notice.question,workPhase:"/private/phase"}),false);
  assert.equal(validQuestionWorkLink({...notice.question,workRef:{...notice.question.workRef,key:"../path"}}),false);
  assert.equal(validQuestionWorkLink({...notice.question,binding:"unbound",workRef:undefined,workPhase:undefined}),true);
  const secret="xox"+"b-"+"a".repeat(20);
  assert.equal(validQuestionWorkLink({...notice.question,ownerEpoch:secret}),false);
  assert.equal(validQuestionWorkLink({...notice.question,workRef:{...notice.question.workRef,key:secret}}),false);
});
