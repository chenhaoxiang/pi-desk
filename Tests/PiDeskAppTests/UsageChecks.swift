import Darwin
import Foundation
import SQLite3

@main enum UsageChecks {
  static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
  static func folder(_ name: String) throws -> URL {
    let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return base
  }
  static func entry(_ root: URL, id: String, at: Date, model: String = "fixture/alpha", values: [Any] = [100, 20, 30, 5]) throws {
    let hash = String(repeating: id, count: 64)
    let shard = root.appendingPathComponent("spool/" + String(hash.prefix(2)))
    try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let bytes = try JSONSerialization.data(withJSONObject: [
      "version": 1, "kind": "usage", "id": hash, "session": String(repeating: "f", count: 64),
      "occurredAt": Int64(at.timeIntervalSince1970 * 1000), "model": model, "source": "pi.assistant.final",
      "tokens": ["input": values[0], "output": values[1], "cacheRead": values[2], "cacheWrite": values[3]],
    ])
    let file = shard.appendingPathComponent(hash + ".json")
    try bytes.write(to: file); chmod(file.path, 0o600)
  }
  static func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }
  static func comparisonFixture(_ range: UsageDateRange, input: Int64, output: Int64) -> UsageAggregate {
    var value = UsageAggregate.empty(range)
    var tokens = UsageTokenTotals(); tokens.add(input: input, output: output, cacheRead: 0, cacheWrite: 0)
    value.buckets = range.days.map { UsageBucket(day: $0, state: .data, tokens: tokens) }
    return value
  }
  static func main() throws {
    let ny = TimeZone(identifier: "America/New_York")!, sh = TimeZone(identifier: "Asia/Shanghai")!
    let spring = UsageDateRange.make(preset: .today, now: date("2024-03-10T16:00:00Z"), timeZone: ny)
    assert(spring.start == date("2024-03-10T05:00:00Z") && spring.end == date("2024-03-11T04:00:00Z"), "DST spring boundaries")
    assert(spring.days.count == 23, "DST 23 hourly buckets")
    let fall = UsageDateRange.make(preset: .today, now: date("2024-11-03T16:00:00Z"), timeZone: ny)
    assert(fall.days.count == 25 && fall.start == date("2024-11-03T04:00:00Z") && fall.end == date("2024-11-04T05:00:00Z"), "DST fall boundaries/hour uniqueness")
    let weekly = UsageDateRange.make(preset: .last7, now: date("2024-04-01T16:00:00Z"), timeZone: ny)
    assert(weekly.days.count == 7 && weekly.start == date("2024-03-26T04:00:00Z"), "7 includes today plus 6")
    let month = UsageDateRange.make(preset: .month, now: date("2024-03-10T16:00:00Z"), timeZone: ny)
    assert(month.start == date("2024-03-01T05:00:00Z") && month.end == date("2024-04-01T04:00:00Z"), "month crosses DST")
    let ordinary = UsageDateRange.make(preset: .today, now: date("2024-04-02T16:00:00Z"), timeZone: ny)
    let currentComparison = comparisonFixture(ordinary, input: 20, output: 10)
    let previousComparison = comparisonFixture(ordinary.previousPeriod, input: 10, output: 5)
    let compareNow = ordinary.start.addingTimeInterval(10.5 * 3600)
    let comparison = UsagePeriodComparison.make(current: currentComparison, previous: previousComparison, metric: .interaction, now: compareNow)
    assert(comparison.issue == nil && comparison.bucketCount == 10 && comparison.current == 300 && comparison.previous == 150 && comparison.percent == 100, "equal-source comparison only uses complete elapsed buckets")
    var missingComparison = previousComparison
    missingComparison.buckets[0] = UsageBucket(day: missingComparison.buckets[0].day, state: .uncollected, tokens: UsageTokenTotals())
    assert(UsagePeriodComparison.make(current: currentComparison, previous: missingComparison, metric: .interaction, now: compareNow).issue != nil, "uncollected is not zero or a decrease")
    var partialTokens = UsageTokenTotals(); partialTokens.add(input: 10, output: nil, cacheRead: 0, cacheWrite: 0)
    missingComparison.buckets[0] = UsageBucket(day: missingComparison.buckets[0].day, state: .data, tokens: partialTokens)
    assert(UsagePeriodComparison.make(current: currentComparison, previous: missingComparison, metric: .interaction, now: compareNow).issue != nil, "missing metric field must suppress delta")
    missingComparison = previousComparison; missingComparison.selectedModel = "fixture/other"
    assert(UsagePeriodComparison.make(current: currentComparison, previous: missingComparison, metric: .interaction, now: compareNow).issue != nil, "different model cannot be compared")
    missingComparison = previousComparison; missingComparison.selectedOrigin = .history
    assert(UsagePeriodComparison.make(current: currentComparison, previous: missingComparison, metric: .interaction, now: compareNow).issue != nil, "different origins cannot be compared")
    for gap in ["recorder-dropped", "recorder-pending", "recorder-write-failure", "history-conflict"] {
      var incomplete = currentComparison
      incomplete.originComparisonGaps[gap.hasPrefix("history") ? "history" : "realtime"] = [gap]
      assert(incomplete.pendingRecords == 0 && UsagePeriodComparison.make(current: incomplete, previous: previousComparison, metric: .interaction, now: compareNow).issue != nil, "known collection loss suppresses delta even after the spool is empty")
    }
    var explanatory = currentComparison
    explanatory.coverageReasons = ["owner totals and tool aggregates are intentionally outside this scope"]
    assert(UsagePeriodComparison.make(current: explanatory, previous: previousComparison, metric: .interaction, now: compareNow).issue == nil, "normal scope descriptions are not collection gaps")
    let gapRoot = try folder("comparison-recorder-gaps")
    _ = UsageLedger.inspect(root: gapRoot, range: ordinary)
    let recorder = gapRoot.appendingPathComponent("recorders/fixture.json")
    for field in ["dropped", "pending", "writeFailures"] {
      var status: [String: Any] = ["version": 1, "kind": "recorder", "dropped": 0, "pending": 0, "writeFailures": 0, "reasons": []]
      status[field] = 1
      try JSONSerialization.data(withJSONObject: status).write(to: recorder); chmod(recorder.path, 0o600)
      let projected = UsageLedger.inspect(root: gapRoot, range: ordinary)
      assert(projected.error == nil && projected.pendingRecords == 0 && !projected.comparisonGaps.isEmpty, "recorder \(field) projects a structured gap independently from spool count")
    }
    try JSONSerialization.data(withJSONObject: ["version": 1, "kind": "recorder", "dropped": 0, "pending": 0, "writeFailures": 0, "reasons": []] as [String: Any]).write(to: recorder)
    chmod(recorder.path, 0o600)
    var gapDB: OpaquePointer?
    assert(sqlite3_open(gapRoot.appendingPathComponent("usage.sqlite3").path, &gapDB) == SQLITE_OK, "open isolated gap fixture")
    assert(sqlite3_exec(gapDB, #"INSERT INTO history_imports VALUES('fixture-import','fixture-source',1000,'applied','{"coverage":{"ambiguous-candidates":1},"conflicts":0}')"#, nil, nil, nil) == SQLITE_OK, "synthetic history gap receipt")
    sqlite3_close(gapDB)
    let historyGap = UsageLedger.inspect(root: gapRoot, range: ordinary)
    assert(historyGap.filtered(origin: .history, model: nil).comparisonGaps.contains("history-incomplete"), "history skipped records block history comparison")
    assert(historyGap.filtered(origin: .realtime, model: nil).comparisonGaps.isEmpty, "history gaps do not poison an explicitly realtime-only comparison")
    assert(sqlite3_open(gapRoot.appendingPathComponent("usage.sqlite3").path, &gapDB) == SQLITE_OK, "reopen isolated gap fixture")
    assert(sqlite3_exec(gapDB, #"UPDATE history_imports SET summary_json='{"coverage":{},"conflicts":1}'"#, nil, nil, nil) == SQLITE_OK, "synthetic history conflict")
    sqlite3_close(gapDB)
    assert(UsageLedger.inspect(root: gapRoot, range: ordinary).filtered(origin: .history, model: nil).comparisonGaps.contains("history-conflict"), "history receipt conflict is a structured gap")
    let zeroComparison = UsagePeriodComparison.make(current: currentComparison, previous: comparisonFixture(ordinary.previousPeriod, input: 0, output: 0), metric: .interaction, now: compareNow)
    assert(zeroComparison.issue == nil && zeroComparison.previous == 0 && zeroComparison.percent == nil, "known zero baseline has no fabricated percentage")
    assert(spring.previousPeriod.start == date("2024-03-09T05:00:00Z") && spring.previousPeriod.end == spring.start, "previous period uses calendar day, not 86400 seconds")
    assert(UsagePeriodComparison.make(current: comparisonFixture(spring, input: 1, output: 1), previous: comparisonFixture(spring.previousPeriod, input: 1, output: 1), metric: .interaction, now: spring.end).issue?.contains("夏令时") == true, "23/24 hours are not silently treated as equal")
    assert(weekly.previousPeriod.end == weekly.start && weekly.previousPeriod.days.count == 7, "weekly comparison is adjacent and equal calendar length")
    let root = try folder("aggregate")
    try entry(root, id: "a", at: spring.start)
    try entry(root, id: "b", at: date("2024-03-10T07:00:00Z"), model: "fixture/beta", values: [40, 10, 5, 0])
    try entry(root, id: "c", at: spring.end, values: [7, 3, 0, 0])
    var result = UsageLedger.inspect(root: root, range: spring)
    if result.error != nil { FileHandle.standardError.write(Data("usage error: \(result.error!)\n".utf8)) }
    assert(result.error == nil && result.recordCount == 2 && result.totals.totalLowerBound == 210, "two sessions and half-open end")
    assert(result.models.count == 2, "model breakdown")
    assert(result.buckets.filter { $0.state == .data }.count == 2, "UTC occurrence bucket")
    assert(result.buckets.contains { $0.state == .uncollected }, "no-data is unknown not zero")
    result = UsageLedger.inspect(root: root, range: spring)
    assert(result.recordCount == 2 && result.totals.totalLowerBound == 210, "reopen restores DB, no volatile snapshot")
    try entry(root, id: "a", at: spring.start)
    result = UsageLedger.inspect(root: root, range: spring)
    assert(result.recordCount == 2, "replay idempotent")
    try entry(root, id: "a", at: spring.start, values: [999, 20, 30, 5])
    result = UsageLedger.inspect(root: root, range: spring)
    assert(result.conflicts == 1 && result.totals.input == 140, "conflict preserves first receipt")
    assert(UsageLedger.inspect(root: root, range: spring).conflicts == 1, "conflict persists across app reopen")
    try entry(root, id: "d", at: date("2024-03-10T08:00:00Z"), values: [5, NSNull(), 0, 0])
    result = UsageLedger.inspect(root: root, range: spring)
    assert(result.totals.input == 145 && result.totals.output == 30 && !result.totals.outputComplete, "missing field retains known lower bound")
    let custom = UsageDateRange.make(preset: .custom, now: spring.start, timeZone: sh, customStart: date("2024-03-10T02:00:00Z"), customEnd: date("2024-03-11T02:00:00Z"))
    assert(custom.start == date("2024-03-09T16:00:00Z") && custom.end == date("2024-03-11T16:00:00Z"), "custom inclusive date input -> half open")
    assert(UsageLedger.inspect(root: root, range: custom).recordCount == 4, "timezone change re-buckets original UTC events")
    let group = DispatchGroup(), lock = NSLock()
    var concurrent: [UsageAggregate] = []
    for _ in 0..<2 {
      group.enter(); DispatchQueue.global().async {
        let snapshot = UsageLedger.inspect(root: root, range: custom)
        lock.lock(); concurrent.append(snapshot); lock.unlock(); group.leave()
      }
    }
    group.wait()
    assert(concurrent.count == 2 && concurrent.allSatisfy { $0.error == nil && $0.recordCount == 4 }, "two index clients serialize without double counting")
    var arithmetic = UsageTokenTotals()
    arithmetic.add(input: 844_557, output: 365_793, cacheRead: 43_735_808, cacheWrite: 0)
    assert(arithmetic.metric(.interaction).value == 1_210_350, "interaction means input plus output only")
    assert(arithmetic.metric(.cache).value == 43_735_808, "cache is separately visible, not new input")
    assert(arithmetic.metric(.processing).value == 44_946_158, "four bucket processing total includes cache exactly once")
    var missing = UsageTokenTotals(); missing.add(input: 10, output: 5, cacheRead: nil, cacheWrite: nil)
    assert(missing.metric(.interaction).value == 15 && missing.metric(.interaction).complete, "missing cache does not poison known interaction sum")
    assert(!missing.metric(.cache).known && missing.metric(.processing).value == 15 && !missing.metric(.processing).complete, "unknown cache is not zero")
    let sample = UsageAggregate.empty(UsageDateRange.make(preset: .last7), preview: true)
    for metric in UsageMetric.allCases {
      assert(sample.models.reduce(0) { $0 + $1.tokens.metric(metric).value } == sample.totals.metric(metric).value, "all model distributions use the selected semantic")
      assert(sample.buckets.reduce(0) { $0 + $1.tokens.metric(metric).value } == sample.totals.metric(metric).value, "all trend buckets use the selected semantic")
    }
    assert(sample.models.reduce(0) { $0 + $1.tokens.totalLowerBound } == sample.totals.totalLowerBound, "synthetic model/total consistency")
    assert(sample.buckets.reduce(0) { $0 + $1.tokens.totalLowerBound } == sample.totals.totalLowerBound, "synthetic chart/total consistency")
    let longRoot = try folder("long-custom-range")
    try entry(longRoot, id: "1", at: date("2025-02-03T12:00:00Z"))
    try entry(longRoot, id: "2", at: date("2025-02-15T12:00:00Z"))
    let utc = TimeZone(secondsFromGMT: 0)!
    let tooLong = UsageDateRange.make(preset: .custom, timeZone: utc, customStart: date("2024-01-01T00:00:00Z"), customEnd: date("2025-03-01T00:00:00Z"))
    let rejectedRange = UsageLedger.inspect(root: longRoot, range: tooLong)
    assert(rejectedRange.error?.contains("400") == true && !rejectedRange.totals.seen && rejectedRange.buckets.isEmpty, "long ranges must explicitly reject, not silently truncate trend/table")
    let boundary = UsageDateRange.make(preset: .custom, timeZone: utc, customStart: date("2024-01-01T00:00:00Z"), customEnd: date("2025-02-03T00:00:00Z"))
    let completeRange = UsageLedger.inspect(root: longRoot, range: boundary)
    assert(boundary.validationIssue == nil && boundary.days.count == 400 && completeRange.error == nil && completeRange.recordCount == 1, "400 inclusive days remain valid")
    assert(completeRange.buckets.reduce(0) { $0 + $1.tokens.totalLowerBound } == completeRange.totals.totalLowerBound, "last admitted day is included in both main number and trend/table")
    let future = UsageDateRange.make(preset: .today, now: date("2099-01-01T00:00:00Z"), timeZone: sh)
    let blank = UsageLedger.inspect(root: root, range: future)
    assert(!blank.totals.seen && blank.buckets.allSatisfy { $0.state == .future }, "future not fake zero")
    let linked = try folder("owned-publish-crash")
    try entry(linked, id: "e", at: spring.start, model: "fixture-gpt/gpt-6.1-sol")
    let published = linked.appendingPathComponent("spool/ee/" + String(repeating: "e", count: 64) + ".json")
    let ownTemp = published.deletingLastPathComponent().appendingPathComponent(".usage-" + UUID().uuidString.lowercased())
    try FileManager.default.linkItem(at: published, to: ownTemp)
    let linkedAttributes = try FileManager.default.attributesOfItem(atPath: published.path)
    assert((linkedAttributes[.referenceCount] as? Int) == 2, "actual two-link crash shape")
    let recovered = UsageLedger.inspect(root: linked, range: spring)
    assert(recovered.error == nil && recovered.recordCount == 1 && recovered.models.first?.model == "fixture-gpt/gpt-6.1-sol", "recover only exact own temp then import")
    assert(!FileManager.default.fileExists(atPath: ownTemp.path), "only proven own temporary link removed")
    let unknown = try folder("unknown-hardlink")
    try entry(unknown, id: "f", at: spring.start)
    let protected = unknown.appendingPathComponent("spool/ff/" + String(repeating: "f", count: 64) + ".json")
    let foreign = unknown.appendingPathComponent("other-owner-link")
    try FileManager.default.linkItem(at: protected, to: foreign)
    let refused = UsageLedger.inspect(root: unknown, range: spring)
    assert(refused.recordCount == 0 && refused.malformed == 1 && FileManager.default.fileExists(atPath: foreign.path), "unknown second link is never imported/deleted")
    var provenanceDB: OpaquePointer?
    precondition(sqlite3_open(root.appendingPathComponent("usage.sqlite3").path,&provenanceDB)==SQLITE_OK)
    let historyID=String(repeating:"a",count:64)
    precondition(sqlite3_exec(provenanceDB,"INSERT INTO usage_provenance VALUES('\(historyID)','history','synthetic-import','assistant','[]',0)",nil,nil,nil)==SQLITE_OK)
    sqlite3_close(provenanceDB)
    let partitioned=UsageLedger.inspect(root:root,range:spring)
    let historical=partitioned.filtered(origin:.history,model:nil), live=partitioned.filtered(origin:.realtime,model:nil)
    assert(historical.recordCount==1 && historical.totals.input==100,"historical source is a provenance tag, not a second consumption key")
    assert(live.recordCount==2 && live.totals.input==45,"live/history split is disjoint")
    assert(historical.totals.metric(.processing).value+live.totals.metric(.processing).value==partitioned.totals.metric(.processing).value,"combined source sum agrees")
    assert(historical.collectedSince==spring.start && live.collectedSince==date("2024-03-10T07:00:00Z"),"source coverage begins at that source, not historical global minimum")
    for source in [historical,live,partitioned] {
      for metric in UsageMetric.allCases {
        assert(source.models.reduce(0){$0+$1.tokens.metric(metric).value}==source.totals.metric(metric).value,"source models sum to the selected source")
        assert(source.buckets.reduce(0){$0+$1.tokens.metric(metric).value}==source.totals.metric(metric).value,"source trend sums to the selected source")
      }
    }
    let historyBeta=partitioned.filtered(origin:.history,model:"fixture/beta")
    assert(historyBeta.recordCount==0 && !historyBeta.totals.seen,"absent source/model stays unknown, not fake zero")
    var combined=UsageTokenTotals();combined.add(historical.totals);combined.add(live.totals)
    assert(combined==partitioned.totals,"source sum preserves partial bucket completeness")
    precondition(sqlite3_open(root.appendingPathComponent("usage.sqlite3").path,&provenanceDB)==SQLITE_OK)
    let aliasID=String(repeating:"9",count:64)
    precondition(sqlite3_exec(provenanceDB,"INSERT INTO usage_aliases VALUES('\(aliasID)','\(historyID)','synthetic-fingerprint','assistant','synthetic-import')",nil,nil,nil)==SQLITE_OK)
    sqlite3_close(provenanceDB)
    try entry(root,id:"9",at:spring.start)
    let replayedAlias=UsageLedger.inspect(root:root,range:spring)
    assert(replayedAlias.recordCount==partitioned.recordCount && replayedAlias.totals==partitioned.totals,"a live replay of a proven fork copy does not add a second row")
    precondition(sqlite3_open(root.appendingPathComponent("usage.sqlite3").path,&provenanceDB)==SQLITE_OK)
    var proof: OpaquePointer?
    sqlite3_prepare_v2(provenanceDB,"SELECT has_realtime FROM usage_provenance WHERE id='\(historyID)'",-1,&proof,nil)
    precondition(sqlite3_step(proof)==SQLITE_ROW && sqlite3_column_int(proof,0)==1)
    sqlite3_finalize(proof);sqlite3_close(provenanceDB)
    let corrupt = try folder("corrupt")
    let corruptFile = corrupt.appendingPathComponent("usage.sqlite3")
    let original = Data("synthetic not a database".utf8); try original.write(to: corruptFile); chmod(corruptFile.path, 0o600)
    assert(UsageLedger.inspect(root: corrupt, range: spring).error != nil, "corrupt DB visible")
    let preserved = try Data(contentsOf: corruptFile)
    assert(preserved == original, "corrupt DB preserved")
    let unsafe = try folder("unsafe")
    let target = try folder("target")
    try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("spool"), withDestinationURL: target)
    assert(UsageLedger.inspect(root: unsafe, range: spring).error != nil, "spool symlink denied")
    var sum = UsageTokenTotals(); sum.add(input: Int64.max, output: 1, cacheRead: 0, cacheWrite: 0); sum.add(input: 1, output: nil, cacheRead: 0, cacheWrite: 0)
    assert(sum.overflow && sum.input == Int64.max && !sum.outputComplete, "overflow/missing fields never wrap")
    print("Usage ledger checks passed: DST/time zones/half-open/custom/future, durable reopen/replay/conflict/missing, corrupt/symlink/overflow.")
  }
}
