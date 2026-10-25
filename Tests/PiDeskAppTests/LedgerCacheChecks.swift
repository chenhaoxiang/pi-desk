import Foundation
import Darwin

@main enum LedgerCacheChecks {
  @MainActor static func refresh(_ ledger: UsageLedger, _ range: UsageDateRange, model: String? = nil) async -> UsageAggregate {
    await withCheckedContinuation { c in ledger.refresh(range: range, model: model) { c.resume(returning: $0) } }
  }
  @MainActor static func diagnostics(_ ledger: UsageLedger) async -> [String: Int] {
    await withCheckedContinuation { c in ledger.diagnostics { c.resume(returning: $0) } }
  }
  static func put(_ root: URL, id: String, model: String, value: Int) throws {
    let full = String(repeating: id, count: 64), dir = root.appendingPathComponent("spool/" + String(full.prefix(2)))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONSerialization.data(withJSONObject: ["version":1,"kind":"usage","id":full,"session":String(repeating:"a",count:64),"occurredAt":Int64(Date().timeIntervalSince1970*1000)-1000,"model":model,"source":"pi.assistant.final","tokens":["input":value,"output":2,"cacheRead":0,"cacheWrite":0]])
    let p = dir.appendingPathComponent(full + ".json"); try data.write(to:p);chmod(p.path,0o600)
  }
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), range = UsageDateRange.make(preset:.today)
    try put(root,id:"a",model:"fixture/deepseek-flash",value:10)
    try put(root,id:"b",model:"fixture/gpt-6.1-sol",value:30)
    let ledger = UsageLedger(root:root)
    let first = await refresh(ledger,range);precondition(first.recordCount==2 && first.models.count==2)
    _ = await refresh(ledger,range) // One post-unlink metadata change is allowed.
    let before = await diagnostics(ledger)
    for _ in 0..<10 { _ = await refresh(ledger,range) }
    let after = await diagnostics(ledger)
    precondition(after["databaseOpens"]==1 && after["aggregateScans"]==before["aggregateScans"] && after["cacheHits",default:0]>=10)
    let gpt=await refresh(ledger,range,model:"fixture/gpt-6.1-sol")
    precondition(gpt.recordCount==1&&gpt.totals.input==30&&gpt.models.count==1&&gpt.models[0].model=="fixture/gpt-6.1-sol")
    precondition(gpt.buckets.reduce(0){$0+$1.tokens.metric(.interaction).value}==gpt.totals.metric(.interaction).value)
    let absent=await refresh(ledger,range,model:"fixture/no-data")
    precondition(absent.recordCount==0 && !absent.totals.anyKnown)
    try put(root,id:"c",model:"fixture/gpt-6.1-sol",value:40)
    let dirty=await refresh(ledger,range)
    precondition(dirty.recordCount==3&&dirty.totals.input==80)
    let incremental = await diagnostics(ledger)
    precondition(incremental["aggregateRows"] == 3, "new final adds one row instead of rescanning the old range")
    precondition(incremental["databaseOpens"] == 1)
    print("Ledger cache checks passed: persistent single DB, no unchanged aggregate/import, dirty shard detection, exact model filter and empty unknown.")
  }
}
