import { types } from "node:util";
import { own, uint } from "./governance-projection.ts";
export type NativeSessionMeta = {
  version: 1; source: "pi.session-manager"; scope: "current-session-records";
  coverage: "not-observed" | "observed" | "partial" | "unavailable";
  observedAt?: number; records?: number; scanned?: number; compactions?: number;
  lastActivityAt?: number; lastActivityKind?: "message" | "compaction" | "branch_summary";
};
const MAX_TIME=7_258_118_400_000,MAX_RECORDS=100_000;
export function validNativeSessionMeta(value: unknown): value is NativeSessionMeta {
  if(own(value,"version")!==1||own(value,"source")!=="pi.session-manager"||own(value,"scope")!=="current-session-records")return false;
  const coverage=own(value,"coverage"),observedAt=own(value,"observedAt"),records=own(value,"records"),scanned=own(value,"scanned"),count=own(value,"compactions"),at=own(value,"lastActivityAt"),kind=own(value,"lastActivityKind");
  if(coverage==="not-observed"||coverage==="unavailable")return [records,scanned,count,at,kind].every(v=>v===undefined)&&(observedAt===undefined||uint(observedAt,MAX_TIME));
  return (coverage==="observed"||coverage==="partial")&&uint(observedAt,MAX_TIME)&&uint(records)&&uint(scanned)&&Number(scanned)<=Number(records)&&uint(count,Number(scanned))
    &&(coverage!=="observed"||scanned===records)&&((at===undefined&&kind===undefined)||(uint(at,MAX_TIME)&&["message","compaction","branch_summary"].some(k=>k===kind)));
}
/** Read only the already-loaded current SessionManager. No context projection,
 * private text, file/history IO, raw serialization, owner mutation or heartbeat scan. */
export class SessionRecordObserver {
  private projection:NativeSessionMeta={version:1,source:"pi.session-manager",scope:"current-session-records",coverage:"not-observed"};
  private initialized=false;private first=0;private processed=0;private compactions=0;private latestAt?:number;private latestKind?:NativeSessionMeta["lastActivityKind"];private bad=false;
  private leaf:unknown=Symbol();private busy=false;private again=false;private stopped=false;private generation=0;
  private sessionId:string;private changed:()=>void;private now:()=>number;
  constructor(sessionId:string,changed:()=>void,now:()=>number=Date.now){this.sessionId=sessionId;this.changed=changed;this.now=now;}
  read(){return {...this.projection};}
  close(){this.stopped=true;this.generation++;}
  sample(manager:unknown,force=false){
    if(this.stopped)return;
    const api=manager as {getSessionId?:()=>string;getLeafId?:()=>unknown;getEntries?:()=>unknown};
    let leaf:unknown;
    try{if(api?.getSessionId?.()!==this.sessionId||typeof api.getEntries!=="function"){this.unavailable();return;}leaf=api.getLeafId?.();}
    catch{this.unavailable();return;}
    if(!force&&leaf!==undefined&&leaf===this.leaf)return;
    if(this.busy){this.again=true;return;}
    this.busy=true;const generation=this.generation;
    setImmediate(()=>{
      if(this.stopped||generation!==this.generation)return;
      let entries:unknown,length:unknown;
      try{if(api.getSessionId?.()!==this.sessionId)throw Error("scope");entries=api.getEntries!();length=own(entries,"length");}
      catch{this.busy=false;this.unavailable();return;}
      if(!Array.isArray(entries)||types.isProxy(entries)||!uint(length)){this.busy=false;this.unavailable();return;}
      const records=length;
      if(!this.initialized||records<this.processed){this.first=Math.max(0,records-MAX_RECORDS);this.processed=this.first;this.compactions=0;this.latestAt=undefined;this.latestKind=undefined;this.bad=false;this.initialized=true;}
      const limit=Math.min(records,this.processed+MAX_RECORDS);
      const chunk=()=>{
        if(this.stopped||generation!==this.generation)return;
        try{if(api.getSessionId?.()!==this.sessionId)throw Error("scope");}catch{this.busy=false;this.unavailable();return;}
        const end=Math.min(this.processed+256,limit);
        while(this.processed<end){
          const entry=own(entries,String(this.processed++)),kind=own(entry,"type");
          if(typeof kind!=="string"){this.bad=true;continue;}
          if(kind==="compaction")this.compactions++;
          if(kind!=="message"&&kind!=="compaction"&&kind!=="branch_summary")continue;
          if(kind==="message"&&!["user","assistant","toolResult","bashExecution"].some(r=>r===own(own(entry,"message"),"role")))continue;
          const raw=own(entry,"timestamp"),at=typeof raw==="string"&&raw.length<=64?Date.parse(raw):NaN;
          if(!uint(at,MAX_TIME)){this.bad=true;continue;}
          // Append order is original order; do not assume the host clock is monotonic.
          this.latestAt=at;this.latestKind=kind;
        }
        if(this.processed<limit){setImmediate(chunk).unref();return;}
        this.leaf=leaf;this.busy=false;
        const now=this.now();if(!uint(now,MAX_TIME)){this.unavailable();return;}
        this.projection={version:1,source:"pi.session-manager",scope:"current-session-records",coverage:this.bad||this.first>0||records>limit?"partial":"observed",observedAt:now,records,scanned:this.processed-this.first,compactions:this.compactions,...(this.latestAt===undefined?{}:{lastActivityAt:this.latestAt,lastActivityKind:this.latestKind})};
        this.changed();if(this.again){this.again=false;this.sample(manager,true);}
      };chunk();
    }).unref();
  }
  private unavailable(){this.projection={version:1,source:"pi.session-manager",scope:"current-session-records",coverage:"unavailable"};this.changed();}
}
