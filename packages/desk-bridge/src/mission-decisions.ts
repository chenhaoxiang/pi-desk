import { createHash, randomUUID } from "node:crypto";
import { dense, own, safeReference, uint, type WorkRef } from "./governance-projection.ts";

export type MissionDecisionRow = { id: string; status: "open" | "resolved"; createdAt: number; resolvedAt?: number };
export type MissionDecisionView = {
  workRef: WorkRef; observedAt: number; sourceUpdatedAt?: number;
  coverage: "complete" | "partial" | "unavailable"; reason?: string;
  counts?: { open: number; resolved: number; total: number }; decisions: MissionDecisionRow[]; omitted: number;
};
export type MissionDecisionsProjection = {
  version: 1; source: "pi.subagents.mission"; scope: string; observerSeq: number;
  coverage: "not-observed" | "observed" | "partial" | "unavailable";
  missions: MissionDecisionView[]; omittedMissions: number;
  /** Cumulative window evictions, not unique missions or unresolved work. */
  evictedRecords: number;
};
const MAX_TIME = 7_258_118_400_000;
const actions = ["mission.create", "mission.show", "mission.update", "mission.resolve-decision", "mission.close"];
const missionId = (value: unknown): value is string => safeReference(value) && /^[A-Za-z0-9]/.test(value) && !value.includes("..");
function timestamp(value: unknown): number | undefined {
  if (typeof value !== "string" || value.length > 64 || !value.trim()) return;
  const ms = Date.parse(value); return uint(ms, MAX_TIME) ? ms : undefined;
}
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
function unavailable(id: string, now: number, reason: string, sourceUpdatedAt?: number): MissionDecisionView {
  return { workRef: {owner:"chenhaoxiang/pi-subagents",kind:"task",key:id}, observedAt:now,
    ...(sourceUpdatedAt === undefined ? {} : {sourceUpdatedAt}), coverage:"unavailable",reason,decisions:[],omitted:0 };
}
type Candidate = { id: string; time?: number; fingerprint: string; view: MissionDecisionView };
/** Only native mission/decision metadata. No title, prompt, resolution, options,
 * source paths, owner session files or raw result content are read/hashed. */
function project(details: unknown, now: number): Candidate | undefined {
  if (own(details,"mode") !== "management") return;
  const record = own(details,"mission"), id = own(details,"missionId");
  if (!missionId(id)) return;
  const time=timestamp(own(record,"updatedAt"));
  const fail=(reason:string):Candidate=>({id,time,fingerprint:reason,view:unavailable(id,now,reason,time)});
  if (own(record,"schemaVersion") !== 1 || own(record,"id") !== id || time === undefined) return fail("source-invalid");
  const raw=dense(own(record,"decisions"),512); if(!raw)return fail("source-unavailable");
  const rows:MissionDecisionRow[]=[],ids=new Set<string>();
  for(const decision of raw){
    const key=own(decision,"id"),status=own(decision,"status"),createdAt=timestamp(own(decision,"createdAt")),resolved=own(decision,"resolvedAt"),resolvedAt=resolved===undefined?undefined:timestamp(resolved);
    if(!missionId(key)||ids.has(key)||(status!=="open"&&status!=="resolved")||createdAt===undefined||(resolved!==undefined&&resolvedAt===undefined))return fail("source-invalid");
    ids.add(key);rows.push({id:key,status,createdAt,...(resolvedAt===undefined?{}:{resolvedAt})});
  }
  rows.sort((a,b)=>a.id < b.id ? -1 : a.id === b.id ? 0 : 1);
  const fingerprint=hash(rows),open=rows.filter(row=>row.status==="open").length;
  const ordered=[...rows.filter(row=>row.status==="open"),...rows.filter(row=>row.status==="resolved")];
  const decisions:MissionDecisionRow[]=[];let bytes=0;
  for(const row of ordered.slice(0,32)){const n=Buffer.byteLength(JSON.stringify(row))+1;if(bytes+n>2800)break;decisions.push(row);bytes+=n;}
  const omitted=rows.length-decisions.length;
  return {id,time,fingerprint,view:{workRef:{owner:"chenhaoxiang/pi-subagents",kind:"task",key:id},observedAt:now,sourceUpdatedAt:time,coverage:omitted?"partial":"complete",counts:{open,resolved:rows.length-open,total:rows.length},decisions,omitted}};
}
export function validMissionDecisions(value: unknown): value is MissionDecisionsProjection {
  if(own(value,"version")!==1||own(value,"source")!=="pi.subagents.mission"||!safeReference(own(value,"scope"))||!uint(own(value,"observerSeq")))return false;
  const coverage=own(value,"coverage"),missions=dense(own(value,"missions"),16),omitted=own(value,"omittedMissions"),evicted=own(value,"evictedRecords");
  if(!["not-observed","observed","partial","unavailable"].some(x=>x===coverage)||!missions||!uint(omitted)||!uint(evicted))return false;
  if(coverage==="not-observed"||coverage==="unavailable")return !missions.length&&omitted===0&&evicted===0;
  const ids=new Set<string>();
  for(const m of missions){
    const ref=own(m,"workRef"),key=own(ref,"key"),state=own(m,"coverage"),rows=dense(own(m,"decisions"),32),count=own(m,"counts"),lost=own(m,"omitted"),time=own(m,"sourceUpdatedAt");
    if(own(ref,"owner")!=="chenhaoxiang/pi-subagents"||own(ref,"kind")!=="task"||!missionId(key)||ids.has(key)||!uint(own(m,"observedAt"),MAX_TIME)||(time!==undefined&&!uint(time,MAX_TIME))||!rows||!uint(lost,512))return false;
    ids.add(key);
    if(state==="unavailable"){if(count!==undefined||rows.length||lost!==0||!safeReference(own(m,"reason")))return false;continue;}
    if(!["complete","partial"].some(x=>x===state)||time===undefined||own(m,"reason")!==undefined)return false;
    const o=own(count,"open"),r=own(count,"resolved"),t=own(count,"total");
    if(!uint(o,512)||!uint(r,512)||!uint(t,512)||o+r!==t||rows.length+lost!==t||(state==="complete"&&lost!==0))return false;
    const rowIds=new Set<string>();let visibleOpen=0;
    for(const row of rows){const id=own(row,"id"),status=own(row,"status"),resolvedAt=own(row,"resolvedAt");if(!missionId(id)||rowIds.has(id)||(status!=="open"&&status!=="resolved")||!uint(own(row,"createdAt"),MAX_TIME)||(resolvedAt!==undefined&&!uint(resolvedAt,MAX_TIME)))return false;rowIds.add(id);if(status==="open")visibleOpen++;}
    if(visibleOpen>o||rows.length-visibleOpen>r)return false;
  }
  return coverage!=="observed"||(omitted===0&&evicted===0&&missions.every(m=>own(m,"coverage")==="complete"));
}
export class MissionDecisionObserver {
  private scope=randomUUID();private seq=0;
  private calls=new Map<string,{scope:string;eligible:boolean;candidate?:Candidate}>();
  private latest=new Map<string,{time?:number;fingerprint:string;conflict:boolean;view:MissionDecisionView}>();
  private evicted=0;
  read():MissionDecisionsProjection {
    const all=[...this.latest.values()].map(x=>x.view),missions:MissionDecisionView[]=[];let bytes=0;
    for(const m of all){const n=Buffer.byteLength(JSON.stringify(m))+1;if(bytes+n>5400)break;missions.push(m);bytes+=n;}
    const omittedMissions=all.length-missions.length;
    return {version:1,source:"pi.subagents.mission",scope:this.scope,observerSeq:this.seq,coverage:!all.length?"not-observed":omittedMissions||this.evicted||missions.some(m=>m.coverage!=="complete")?"partial":"observed",missions,omittedMissions,evictedRecords:this.evicted};
  }
  reset(){this.scope=randomUUID();this.seq++;this.calls.clear();this.latest.clear();this.evicted=0;}
  start(id:string){if(typeof id==="string"&&id.length<=512&&this.calls.size<32&&!this.calls.has(id))this.calls.set(id,{scope:this.scope,eligible:false});}
  result(event:unknown){
    const id=own(event,"toolCallId"),call=typeof id==="string"?this.calls.get(id):undefined;
    if(!call||call.scope!==this.scope||own(event,"toolName")!=="subagent"||own(event,"isError")!==false)return;
    const input=own(event,"input"),action=own(input,"action");if(!actions.some(a=>a===action))return;
    const details=own(event,"details"),candidate=project(details,0);if(!candidate)return;
    const direct=own(input,"missionId"),nested=own(own(input,"options"),"missionId");
    if(action!=="mission.create"&&((direct??nested)!==candidate.id||(direct!==undefined&&direct!==candidate.id)||(nested!==undefined&&nested!==candidate.id)))return;
    call.eligible=true;call.candidate=candidate;
  }
  end(id:string,result:unknown,failed:boolean,now:number):boolean {
    const call=this.calls.get(id);this.calls.delete(id);
    if(!call?.eligible||!call.candidate||call.scope!==this.scope||failed||own(result,"isError")===true||!uint(now,MAX_TIME))return false;
    const final=project(own(result,"details"),now),first=call.candidate;
    const candidate=final&&final.id===first.id&&final.time===first.time&&final.fingerprint===first.fingerprint?final:{...first,view:unavailable(first.id,now,"finalized-mismatch",first.time),fingerprint:"finalized-mismatch"};
    const previous=this.latest.get(candidate.id);
    if(previous?.time!==undefined&&candidate.time!==undefined&&candidate.time<previous.time)return false;
    if(previous&&previous.time===candidate.time){
      if(previous.conflict||previous.fingerprint===candidate.fingerprint)return false;
      this.latest.set(candidate.id,{time:candidate.time,fingerprint:"conflict",conflict:true,view:unavailable(candidate.id,now,"same-time-conflict",candidate.time)});this.seq++;return true;
    }
    const watermark=candidate.time??previous?.time;
    // Missing timestamps cannot erase a known original watermark or clear an
    // equal-time conflict. Only a newer valid native record can resolve it.
    if(previous?.conflict&&(candidate.time===undefined||candidate.time<=previous.time!))return false;
    // Retain first-observed order when an existing record changes; no live list jumps.
    this.latest.set(candidate.id,{time:watermark,fingerprint:candidate.fingerprint,conflict:false,view:candidate.view});
    if(this.latest.size>16){this.latest.delete(this.latest.keys().next().value!);this.evicted++;}
    this.seq++;return true;
  }
}
