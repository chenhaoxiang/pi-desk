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
