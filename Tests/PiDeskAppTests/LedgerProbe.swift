import Foundation
@main enum LedgerProbe {
  static func main() throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let value = UsageLedger.inspect(root: root, range: .make(preset: .month))
    let output: [String: Any] = ["ok":value.error == nil,"error":value.error ?? "","records":value.recordCount,"models":value.models.map { ["model":$0.model,"input":$0.tokens.input,"output":$0.tokens.output,"cacheRead":$0.tokens.cacheRead,"cacheWrite":$0.tokens.cacheWrite] as [String:Any] },"input":value.totals.input,"output":value.totals.output,"cacheRead":value.totals.cacheRead,"cacheWrite":value.totals.cacheWrite,"interaction":value.totals.metric(.interaction).value,"processing":value.totals.metric(.processing).value,"pending":value.pendingRecords,"malformed":value.malformed]
    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]),as:UTF8.self))
    if value.error != nil { exit(1) }
  }
}
