import Foundation
import Darwin

// Explicit metadata-only canonical/isolated ledger check. No JSONL or body reads.
@main enum LargeLedgerChecks {
  @MainActor static func refresh(_ ledger: UsageLedger, range: UsageDateRange, origin: UsageOrigin = .combined, model: String? = nil) async -> (UsageAggregate, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value: UsageAggregate = await withCheckedContinuation { c in
      ledger.refresh(range: range, model: model, origin: origin) { c.resume(returning: $0) }
    }
    return (value, (ProcessInfo.processInfo.systemUptime - start) * 1000)
  }
  @MainActor static func diagnostics(_ ledger: UsageLedger) async -> [String: Int] {
    await withCheckedContinuation { c in ledger.diagnostics { c.resume(returning: $0) } }
  }
  @MainActor static func main() async {
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let ledger = UsageLedger(root: root), range = UsageDateRange.make(preset: .month)
    let (first, cold) = await refresh(ledger, range: range)
    precondition(first.error == nil)
    _ = await refresh(ledger, range: range) // Settle the indexer's own spool-unlink generation.
    let before = await diagnostics(ledger)
    var times: [Double] = [], value = first
    for _ in 0..<10 {
      let (next, elapsed) = await refresh(ledger, range: range)
      value = next; times.append(elapsed)
    }
    let after = await diagnostics(ledger)
    var switchTimes: [Double] = []
    for origin in [UsageOrigin.history, .realtime, .combined] {
      let (selected, elapsed) = await refresh(ledger, range: range, origin: origin, model: first.availableModels.first)
      precondition(selected.selectedOrigin == origin)
      switchTimes.append(elapsed)
    }
    let final = await diagnostics(ledger)
    let stable = before["aggregateRows"] == after["aggregateRows"]
    if first.recordCount == value.recordCount { precondition(stable, "unchanged canonical input must not rescan aggregate rows") }
    precondition(after["databaseOpens"] == 1)
    let out: [String: Any] = [
      "ok": true, "metadataOnly": true, "preset": "month", "origin": "combined", "model": "all",
      "initialRecords": first.recordCount, "finalRecords": value.recordCount, "inputStable": first.recordCount == value.recordCount,
      "coldMs": cold, "warmRefreshMs": times, "sourceModelProjectionMs": switchTimes,
      "diagnosticsBefore": before, "diagnosticsAfter": after, "diagnosticsFinal": final,
      "sameRangeRepeatedAggregateRows": after["aggregateRows", default: 0] - before["aggregateRows", default: 0],
      "sameRangeRepeatedAggregateScans": after["aggregateScans", default: 0] - before["aggregateScans", default: 0],
      "cacheHitsAdded": after["cacheHits", default: 0] - before["cacheHits", default: 0],
      "zeroNewRowsMustHaveNoAggregateRescan": (first.recordCount != value.recordCount) || after["aggregateRows"] == before["aggregateRows"],
      "realProviderCalls": 0
    ]
    print(String(data: try! JSONSerialization.data(withJSONObject: out, options: .sortedKeys), encoding: .utf8)!)
  }
}
