import Foundation
import Darwin
import SQLite3

@main enum SessionMetricsChecks {
  static func date(_ s: String)->Date { ISO8601DateFormatter().date(from:s)! }
  static func entry(_ root: URL,_ id:String,_ session:String,_ at:Date,_ value:Any) throws {
    let key=String(repeating:id,count:64),dir=root.appendingPathComponent("spool/"+key.prefix(2))
    try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let data=try JSONSerialization.data(withJSONObject:["version":1,"kind":"usage","id":key,"session":session,"occurredAt":Int64(at.timeIntervalSince1970*1000),"model":"fixture/model","source":"pi.assistant.final","tokens":["input":value,"output":0,"cacheRead":0,"cacheWrite":0]])
    let file=dir.appendingPathComponent(key+".json");try data.write(to:file);chmod(file.path,0o600)
  }
  @MainActor static func main() async throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]),session=String(repeating:"a",count:64),other=String(repeating:"b",count:64)
    let zone=TimeZone(identifier:"America/New_York")!,now=date("2024-11-09T18:00:00Z")
    try entry(root,"1",session,date("2024-11-09T05:00:00Z"),10)
    try entry(root,"2",session,date("2024-11-03T04:00:00Z"),20) // exact 7-day start, before DST falls back
    try entry(root,"3",session,date("2024-10-11T04:00:00Z"),30) // exact 30-day start
    try entry(root,"4",session,date("2024-10-11T03:59:59Z"),40)
    try entry(root,"5",other,date("2024-11-09T06:00:00Z"),999)
    try entry(root,"6",session,date("2024-11-10T06:00:00Z"),100) // future relative to requested now
    let ledger=UsageLedger(root:root)
    let summary:SessionUsageSummary=await withCheckedContinuation { done in ledger.refreshSession(session:session,now:now,timeZone:zone){done.resume(returning:$0)} }
    precondition(summary.error==nil && summary.recordCount==4 && summary.total.totalLowerBound==100)
    precondition(summary.today.totalLowerBound==10 && summary.last7.totalLowerBound==30 && summary.last30.totalLowerBound==60,"calendar windows include exact boundary, DST and exclude other sessions/future")
    precondition(summary.earliestAt==date("2024-10-11T03:59:59Z"))
    try entry(root,"1",session,date("2024-11-09T05:00:00Z"),10)
    let repeated:SessionUsageSummary=await withCheckedContinuation { done in ledger.refreshSession(session:session,now:now,timeZone:zone){done.resume(returning:$0)} }
    precondition(repeated.recordCount==4 && repeated.total.totalLowerBound==100,"replay uses original receipt idempotence")
    var db:OpaquePointer?;precondition(sqlite3_open(root.appendingPathComponent("usage.sqlite3").path,&db)==SQLITE_OK)
    let alias="INSERT INTO usage_aliases VALUES('"+String(repeating:"2",count:64)+"','"+String(repeating:"1",count:64)+"','fixture','assistant','fixture-import')"
    precondition(sqlite3_exec(db,alias,nil,nil,nil)==SQLITE_OK);sqlite3_close(db)
    let dealiased:SessionUsageSummary=await withCheckedContinuation { done in ledger.refreshSession(session:session,now:now,timeZone:zone){done.resume(returning:$0)} }
    precondition(dealiased.recordCount==3 && dealiased.total.totalLowerBound==80 && dealiased.last7.totalLowerBound==10,"fork/history alias exclusion matches original ledger aggregate")
    let times:[String:Double]=await withCheckedContinuation { done in ledger.latestInteractions(sessions:[session,other]){done.resume(returning:$0 ?? [:])} }
    precondition(times[session] != nil && times[other] != nil)
    let noData:SessionUsageSummary=await withCheckedContinuation { done in ledger.refreshSession(session:String(repeating:"c",count:64),now:now,timeZone:zone){done.resume(returning:$0)} }
    precondition(noData.recordCount==0 && !noData.total.anyKnown && !noData.today.anyKnown,"unrecorded is not a known zero")
    let invalid:SessionUsageSummary=await withCheckedContinuation { done in ledger.refreshSession(session:"not-a-session-hash",now:now,timeZone:zone){done.resume(returning:$0)} }
    precondition(invalid.error != nil)
    print("Session metrics ledger checks passed: same DB/receipts, exact session, all/1/7/30 calendar windows, DST boundaries, replay, aliases, missing coverage and no fake zero.")
  }
}
