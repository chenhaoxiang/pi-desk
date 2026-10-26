import Darwin
import CryptoKit
import Foundation
import SQLite3

public enum UsagePreset: String, CaseIterable, Identifiable {
  case today = "今日"
  case last7 = "近7天"
  case month = "本月"
  case custom = "自定义"
  public var id: String { rawValue }
}

public struct UsageDateRange: Equatable, Hashable {
  public var start: Date
  public var end: Date
  public var preset: UsagePreset
  public var timeZone: TimeZone

  public static func make(
    preset: UsagePreset, now: Date = Date(), timeZone: TimeZone = .current,
    customStart: Date? = nil, customEnd: Date? = nil
  ) -> UsageDateRange {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let today = calendar.startOfDay(for: now)
    switch preset {
    case .today:
      return UsageDateRange(
        start: today, end: calendar.date(byAdding: .day, value: 1, to: today)!, preset: preset,
        timeZone: timeZone)
    case .last7:
      return UsageDateRange(
        start: calendar.date(byAdding: .day, value: -6, to: today)!,
        end: calendar.date(byAdding: .day, value: 1, to: today)!, preset: preset,
        timeZone: timeZone)
    case .month:
      let monthStart = calendar.date(
        from: calendar.dateComponents([.era, .year, .month], from: today))!
      return UsageDateRange(
        start: monthStart, end: calendar.date(byAdding: .month, value: 1, to: monthStart)!,
        preset: preset, timeZone: timeZone)
    case .custom:
      let start = calendar.startOfDay(for: customStart ?? today)
      let endDay = calendar.startOfDay(for: customEnd ?? start)
      let end = calendar.date(byAdding: .day, value: 1, to: max(start, endDay))!
      return UsageDateRange(start: start, end: end, preset: preset, timeZone: timeZone)
    }
  }

  public var endDate: Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(byAdding: .day, value: -1, to: end) ?? start
  }

  public var hourly: Bool { timeZoneCalendar.date(byAdding: .day, value: 1, to: start) == end }
  public var days: [Date] {
    var output: [Date] = [], cursor = start
    while cursor < end, output.count < 400 {
      output.append(cursor)
      cursor = timeZoneCalendar.date(byAdding: hourly ? .hour : .day, value: 1, to: cursor) ?? end
    }
    return output
  }
  public func bucketEnd(_ date: Date) -> Date { timeZoneCalendar.date(byAdding: hourly ? .hour : .day, value: 1, to: date) ?? end }
  public func bucket(for date: Date) -> Date {
    hourly ? (timeZoneCalendar.dateInterval(of: .hour, for: date)?.start ?? date) : timeZoneCalendar.startOfDay(for: date)
  }
}

public enum UsageOrigin: String, CaseIterable, Identifiable {
  case combined, realtime, history
  public var id: String { rawValue }
  public var title: String { switch self { case .combined: return "合计"; case .realtime: return "实时记录"; case .history: return "一次性历史补采" } }
}
public enum UsageMetric: String, CaseIterable, Identifiable {
  case interaction, cache, processing
  public var id: String { rawValue }
  public var selector: String { switch self { case .interaction: return "交互"; case .cache: return "缓存"; case .processing: return "全部" } }
  public var title: String { switch self { case .interaction: return "交互 Token"; case .cache: return "缓存用量"; case .processing: return "记录总处理量" } }
  public var explanation: String { switch self {
    case .interaction: return "输入 + 输出，不含缓存复用"
    case .cache: return "缓存读取 + 缓存写入，表示上下文复用/写入量"
    case .processing: return "输入 + 输出 + 缓存读取 + 缓存写入；四桶下界，不是新输入或账单"
  } }
  public var indices: [Int] { switch self { case .interaction: return [0, 1]; case .cache: return [2, 3]; case .processing: return [0, 1, 2, 3] } }
}
public struct UsageMetricValue: Equatable {
  public var value: Int64
  public var known: Bool
  public var complete: Bool
}
public struct UsageTokenTotals: Equatable {
  public var input: Int64 = 0
  public var output: Int64 = 0
  public var cacheRead: Int64 = 0
  public var cacheWrite: Int64 = 0
  public var inputComplete = true
  public var outputComplete = true
  public var cacheReadComplete = true
  public var cacheWriteComplete = true
  public var inputKnown = false
  public var outputKnown = false
  public var cacheReadKnown = false
  public var cacheWriteKnown = false
  public var seen = false
  public var overflow = false

  public mutating func add(
    input: Int64?, output: Int64?, cacheRead: Int64?, cacheWrite: Int64?
  ) {
    seen = true
    inputKnown = inputKnown || input != nil; outputKnown = outputKnown || output != nil
    cacheReadKnown = cacheReadKnown || cacheRead != nil; cacheWriteKnown = cacheWriteKnown || cacheWrite != nil
    let a = Self.sum(self.input, input), b = Self.sum(self.output, output)
    let c = Self.sum(self.cacheRead, cacheRead), d = Self.sum(self.cacheWrite, cacheWrite)
    self.input = a.value; self.output = b.value; self.cacheRead = c.value; self.cacheWrite = d.value
    inputComplete = inputComplete && input != nil && !a.overflow
    outputComplete = outputComplete && output != nil && !b.overflow
    cacheReadComplete = cacheReadComplete && cacheRead != nil && !c.overflow
    cacheWriteComplete = cacheWriteComplete && cacheWrite != nil && !d.overflow
    overflow = overflow || a.overflow || b.overflow || c.overflow || d.overflow
  }

  private static func sum(_ value: Int64, _ increment: Int64?) -> (value: Int64, overflow: Bool) {
    guard let increment else { return (value, false) }
    let result = value.addingReportingOverflow(increment)
    return result.overflow || increment < 0 ? (value, true) : (result.partialValue, false)
  }

  public mutating func add(_ other: UsageTokenTotals) {
    guard other.seen else { return }
    add(input: other.inputKnown ? other.input : nil, output: other.outputKnown ? other.output : nil,
      cacheRead: other.cacheReadKnown ? other.cacheRead : nil, cacheWrite: other.cacheWriteKnown ? other.cacheWrite : nil)
    inputComplete = inputComplete && other.inputComplete
    outputComplete = outputComplete && other.outputComplete
    cacheReadComplete = cacheReadComplete && other.cacheReadComplete
    cacheWriteComplete = cacheWriteComplete && other.cacheWriteComplete
    overflow = overflow || other.overflow
  }

  public var totalLowerBound: Int64 {
    var result: Int64 = 0
    for value in [input, output, cacheRead, cacheWrite] {
      let sum = result.addingReportingOverflow(value)
      if sum.overflow { return Int64.max }
      result = sum.partialValue
    }
    return result
  }

  public func metric(_ metric: UsageMetric) -> UsageMetricValue {
    let values = [input, output, cacheRead, cacheWrite]
    let known = [inputKnown, outputKnown, cacheReadKnown, cacheWriteKnown]
    let complete = [inputComplete, outputComplete, cacheReadComplete, cacheWriteComplete]
    var sum: Int64 = 0, sumOverflow = false
    for index in metric.indices {
      let next = sum.addingReportingOverflow(values[index])
      if next.overflow { sum = Int64.max; sumOverflow = true } else { sum = next.partialValue }
    }
    return UsageMetricValue(value: sum, known: metric.indices.contains { known[$0] },
      complete: seen && !sumOverflow && metric.indices.allSatisfy { known[$0] && complete[$0] })
  }
  public var anyKnown: Bool { inputKnown || outputKnown || cacheReadKnown || cacheWriteKnown }
  public var complete: Bool {
    seen && inputComplete && outputComplete && cacheReadComplete && cacheWriteComplete && !overflow
  }
}

public enum UsageBucketState: String {
  case data
  case uncollected
  case future
}

public struct UsageBucket: Identifiable, Equatable {
  public let day: Date
  public let state: UsageBucketState
  public let tokens: UsageTokenTotals
  public var id: Date { day }
}

public struct UsageModelTotal: Identifiable, Equatable {
  public let model: String
  public let tokens: UsageTokenTotals
  public var id: String { model }
}

public struct UsageAggregate: Equatable {
  public var range: UsageDateRange
  public var timeZoneID: String
  public var totals = UsageTokenTotals()
  public var buckets: [UsageBucket] = []
  public var models: [UsageModelTotal] = []
  public var availableModels: [String] = []
  public var selectedModel: String?
  public var selectedOrigin: UsageOrigin = .combined
  public var originTotals: [String: UsageTokenTotals] = [:]
  public var originCounts: [String: Int] = [:]
  public var originCollectedSince: [String: Date] = [:]
  public var originModels: [String: [String: UsageTokenTotals]] = [:]
  public var originBuckets: [String: [Date: UsageTokenTotals]] = [:]
  public var originModelBuckets: [String: [String: [Date: UsageTokenTotals]]] = [:]
  public var originModelCounts: [String: [String: Int]] = [:]
  public var historyImportedAt: Date?
  public var historyMinDate: Date?
  public var historyMaxDate: Date?
  public var historyReasons: [String] = []
  public var modelBuckets: [String: [Date: UsageTokenTotals]] = [:]
  public var modelRecordCounts: [String: Int] = [:]
  public var recordCount = 0
  public var collectedSince: Date?
  public var pendingRecords = 0
  public var conflicts = 0
  public var malformed = 0
  public var coverageReasons: [String] = []
  public var error: String?
  public var refreshedAt: Date?

  public func filtered(origin: UsageOrigin, model: String?) -> UsageAggregate {
    if origin == .combined { var value = filtered(model: model); value.selectedOrigin = .combined; return value }
    var value = self
    value.selectedOrigin = origin
    value.totals = originTotals[origin.rawValue] ?? UsageTokenTotals()
    value.recordCount = originCounts[origin.rawValue] ?? 0
    value.collectedSince = originCollectedSince[origin.rawValue]
    value.models = (originModels[origin.rawValue] ?? [:]).map { UsageModelTotal(model: $0.key, tokens: $0.value) }
    value.modelBuckets = originModelBuckets[origin.rawValue] ?? [:]
    value.modelRecordCounts = originModelCounts[origin.rawValue] ?? [:]
    let totals = originBuckets[origin.rawValue] ?? [:]
    value.buckets = buckets.map { b in UsageBucket(day:b.day,state:b.state == .future ? .future : (totals[b.day] == nil ? .uncollected : .data),tokens:totals[b.day] ?? UsageTokenTotals()) }
    return value.filtered(model: model)
  }
  public func filtered(model: String?) -> UsageAggregate {
    guard let model else { return self }
    var result = self
    result.selectedModel = model
    result.totals = models.first(where: { $0.model == model })?.tokens ?? UsageTokenTotals()
    result.models = models.filter { $0.model == model }
    result.recordCount = modelRecordCounts[model] ?? 0
    for origin in ["realtime","history"] {
      result.originTotals[origin] = originModels[origin]?[model] ?? UsageTokenTotals()
      result.originCounts[origin] = originModelCounts[origin]?[model] ?? 0
    }
    let values = modelBuckets[model] ?? [:]
    result.buckets = buckets.map { bucket in
      UsageBucket(day: bucket.day, state: bucket.state == .future ? .future : (values[bucket.day] == nil ? .uncollected : .data), tokens: values[bucket.day] ?? UsageTokenTotals())
    }
    return result
  }

  public static func empty(_ range: UsageDateRange, preview: Bool = false) -> UsageAggregate {
    var result = UsageAggregate(range: range, timeZoneID: range.timeZone.identifier)
    if preview {
      let calendar = range.timeZoneCalendar, now = Date()
      let today = calendar.startOfDay(for: now)
      var byBucket: [Date: UsageTokenTotals] = [:], byModel: [String: UsageTokenTotals] = [:]
      for dayOffset in -5...0 {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
        for hour in [1, 5, 10, 14] {
          let time = calendar.date(byAdding: .hour, value: hour, to: day)!
          guard time <= now, time >= range.start, time < range.end else { continue }
          let n = Int64((dayOffset + 6 + hour) % 4 + 1)
          for (name, input, output, cacheRead, cacheWrite) in [
            ("gpt-6.1-sol", n * 140_000, n * 28_000, n * 580_000, n * 6_000),
            ("gpt-5-mini", n * 40_000, n * 6_000, n * 120_000, n * 2_000)
          ] {
            result.totals.add(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            var t = byBucket[range.bucket(for: time)] ?? UsageTokenTotals()
            t.add(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite); byBucket[range.bucket(for: time)] = t
            var m = byModel[name] ?? UsageTokenTotals()
            m.add(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite); byModel[name] = m
            var mt = result.modelBuckets[name]?[range.bucket(for: time)] ?? UsageTokenTotals()
            mt.add(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
            result.modelBuckets[name, default: [:]][range.bucket(for: time)] = mt
            result.modelRecordCounts[name, default: 0] += 1
            result.recordCount += 1
          }
        }
      }
      result.buckets = range.days.map { date in
        UsageBucket(day: date, state: date > range.bucket(for: now) ? .future : (byBucket[date] == nil ? .uncollected : .data), tokens: byBucket[date] ?? UsageTokenTotals())
      }
      result.models = byModel.map { UsageModelTotal(model: $0.key, tokens: $0.value) }.sorted { $0.tokens.totalLowerBound > $1.tokens.totalLowerBound }
      result.availableModels = result.models.map(\.model).sorted()
      result.collectedSince = calendar.date(byAdding: .day, value: -5, to: today)
      result.coverageReasons = ["纯合成预览；工具/子任务附加量可能未覆盖"]
      result.originTotals["realtime"]=result.totals;result.originCounts["realtime"]=result.recordCount
      result.originCollectedSince["realtime"]=result.collectedSince
      result.originModels["realtime"]=Dictionary(uniqueKeysWithValues:result.models.map{($0.model,$0.tokens)})
      result.originBuckets["realtime"]=Dictionary(uniqueKeysWithValues:result.buckets.filter{$0.state == .data}.map{($0.day,$0.tokens)})
      result.originModelBuckets["realtime"]=result.modelBuckets;result.originModelCounts["realtime"]=result.modelRecordCounts
      result.refreshedAt = Date()
    } else {
      result.buckets = range.days.map { UsageBucket(day: $0, state: .uncollected, tokens: UsageTokenTotals()) }
    }
    return result
  }
}

private struct DiskTokens: Decodable {
  let input: Int64?
  let output: Int64?
  let cacheRead: Int64?
  let cacheWrite: Int64?
}
private struct DiskUsageEntry: Decodable {
  let version: Int
  let kind: String
  let id: String
  let session: String
  let occurredAt: Int64
  let model: String
  let source: String
  let tokens: DiskTokens
}
private struct DiskRecorder: Decodable {
  let version: Int
  let kind: String
  let pending: Int
  let dropped: Int
  let writeFailures: Int
  let reasons: [String]
}

protocol UsageLedgerClient: AnyObject {
  func refresh(range: UsageDateRange, completion: @escaping (UsageAggregate) -> Void)
  func refresh(range: UsageDateRange, model: String?, completion: @escaping (UsageAggregate) -> Void)
  func refresh(range: UsageDateRange, model: String?, origin: UsageOrigin, completion: @escaping (UsageAggregate) -> Void)
}
extension UsageLedgerClient {
  func refresh(range: UsageDateRange, model: String?, origin: UsageOrigin, completion: @escaping (UsageAggregate) -> Void) {
    refresh(range: range) { completion($0.filtered(origin: origin, model: model)) }
  }
  func refresh(range: UsageDateRange, model: String?, completion: @escaping (UsageAggregate) -> Void) {
    refresh(range: range) { completion($0.filtered(model: model)) }
  }
}

public final class UsageLedger: UsageLedgerClient {
  private let queue = DispatchQueue(label: "io.github.chenhaoxiang.pi-desk.usage-ledger", qos: .utility)
  private let root: URL
  private var database: Database?
  private var cachedRange: UsageDateRange?
  private var cachedGeneration: String?
  private var cachedAggregate: UsageAggregate?
  private var cacheBucket: Date?
  private var counters = ["databaseOpens": 0, "importScans": 0, "aggregateScans": 0, "cacheHits": 0]

  public init(root: URL? = nil) {
    if let root {
      self.root = root
    } else if let env = ProcessInfo.processInfo.environment["PI_DESK_USAGE_DIR"], env.hasPrefix("/") {
      self.root = URL(fileURLWithPath: env)
    } else {
      self.root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PiDesk/usage-v1", isDirectory: true)
    }
  }

  private var pendingRefresh: (range: UsageDateRange, model: String?, origin: UsageOrigin, completion: (UsageAggregate) -> Void)?
  private var isRefreshing = false
  public func refresh(range: UsageDateRange, completion: @escaping (UsageAggregate) -> Void) {
    refresh(range: range, model: nil, completion: completion)
  }
  public func refresh(range: UsageDateRange, model: String?, completion: @escaping (UsageAggregate) -> Void) {
    refresh(range:range,model:model,origin:.combined,completion:completion)
  }
  public func refresh(range: UsageDateRange, model: String?, origin: UsageOrigin, completion: @escaping (UsageAggregate) -> Void) {
    pendingRefresh = (range, model, origin, completion)
    if !isRefreshing { runNextRefresh() }
  }
  private func runNextRefresh() {
    guard let work = pendingRefresh else { isRefreshing = false; return }
    pendingRefresh = nil; isRefreshing = true
    queue.async { [weak self] in
      guard let self else { return }
      let result = self.readIncremental(range: work.range).filtered(origin:work.origin, model: work.model)
      DispatchQueue.main.async {
        if self.pendingRefresh != nil { self.runNextRefresh() }
        else { self.isRefreshing = false; work.completion(result) }
      }
    }
  }
  private func readIncremental(range: UsageDateRange) -> UsageAggregate {
    do {
      try Self.secureDirectory(root)
      if database == nil {
        database = try Database(root: root)
        counters["databaseOpens", default: 0] += 1
        counters["healthChecks", default: 0] += 1
        counters["schemaInitializations", default: 0] += 1
      }
      let db = database!
      let generation = try metadataGeneration(db: db)
      if let cachedAggregate, cachedRange == range, cachedGeneration == generation, cacheBucket == range.bucket(for: Date()) {
        counters["cacheHits", default: 0] += 1
        var value = cachedAggregate; value.refreshedAt = Date(); return value
      }
      counters["importScans", default: 0] += 1
      let importResult = try db.importSpool()
      counters["aggregateScans", default: 0] += 1
      var aggregate = try db.aggregate(range: range)
      counters["aggregateRows", default: 0] += db.lastAggregateRows
      aggregate.pendingRecords = importResult.pending
      aggregate.malformed = importResult.malformed
      aggregate.conflicts = importResult.conflicts
      if aggregate.conflicts > 0 { aggregate.coverageReasons.append("重复receipt内容冲突，保留首次记录") }
      aggregate.coverageReasons = Array(Set(aggregate.coverageReasons + importResult.reasons)).sorted()
      aggregate.refreshedAt = Date()
      // Bind the pre-import generation: any concurrent publish is necessarily
      // dirty on the next refresh (our own unlink may cause one cheap extra pass).
      cachedRange = range; cachedGeneration = generation; cachedAggregate = aggregate; cacheBucket = range.bucket(for: Date())
      return aggregate
    } catch {
      var aggregate = UsageAggregate.empty(range)
      aggregate.error = Self.errorText(error)
      aggregate.coverageReasons = ["本地用量索引不可用；旧数据未清空，Pi继续独立运行"]
      aggregate.refreshedAt = Date()
      return aggregate
    }
  }

  public func diagnostics(_ completion: @escaping ([String: Int]) -> Void) {
    queue.async { let value = self.counters; DispatchQueue.main.async { completion(value) } }
  }
  private func metadataGeneration(db: Database) throws -> String {
    let spool = root.appendingPathComponent("spool")
    let dirs = ((try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []).filter { $0.lastPathComponent.range(of: "^[a-f0-9]{2}$", options: .regularExpression) != nil }.prefix(256)
    var parts = [String(try db.scalar("PRAGMA data_version"))]
    for url in [spool, root.appendingPathComponent("recorders")] + Array(dirs) {
      var info = stat()
      guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw LedgerError.unsafeStorage }
      parts.append(url.lastPathComponent + ":" + String(info.st_ino) + ":" + String(info.st_mtimespec.tv_sec) + ":" + String(info.st_mtimespec.tv_nsec))
    }
    return parts.sorted().joined(separator: "|")
  }
  private static func errorText(_ error: Error) -> String {
    let text = String(describing: error)
    return text.count <= 120 ? text : String(text.prefix(120))
  }

  private static func secureDirectory(_ url: URL) throws {
    guard url.path.hasPrefix("/"), url.standardized.path == url.path else { throw LedgerError.unsafeStorage }
    var path = ""
    for part in url.path.split(separator: "/") {
      path += "/" + part
      var info = stat()
      if lstat(path, &info) != 0 {
        guard errno == ENOENT, mkdir(path, 0o700) == 0, lstat(path, &info) == 0 else { throw LedgerError.unsafeStorage }
      }
      guard info.st_mode & S_IFMT == S_IFDIR else { throw LedgerError.unsafeStorage }
    }
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
      info.st_mode & S_IFMT == S_IFDIR else { throw LedgerError.unsafeStorage }
  }
  private enum LedgerError: Error { case unsafeStorage, databaseUnavailable, incompatibleSchema, fileMissing }
  private static func readPrivate(_ url: URL) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw errno == ENOENT ? LedgerError.fileMissing : LedgerError.unsafeStorage }
    defer { Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size <= 4096 else { throw LedgerError.unsafeStorage }
    var bytes = [UInt8](repeating: 0, count: 4097)
    let count = Darwin.read(fd, &bytes, bytes.count)
    guard count >= 0, count <= 4096 else { throw LedgerError.unsafeStorage }
    return Data(bytes.prefix(count))
  }
  public static func inspect(root: URL, range: UsageDateRange) -> UsageAggregate { UsageLedger(root: root).readIncremental(range: range) }

  private static func recoverOwnPublishLink(_ file: URL) throws -> Bool {
    let dir = file.deletingLastPathComponent()
    var quick = stat()
    guard lstat(file.path, &quick) == 0, quick.st_nlink == 2, quick.st_mode & S_IFMT == S_IFREG else { return false }
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var final = stat()
    guard fstat(fd, &final) == 0, final.st_mode & S_IFMT == S_IFREG, final.st_uid == getuid(),
      final.st_mode & 0o077 == 0, final.st_nlink == 2, final.st_size > 0, final.st_size <= 4096 else { return false }
    var bytes = [UInt8](repeating: 0, count: 4097)
    let n = Darwin.read(fd, &bytes, bytes.count)
    guard n > 0, n <= 4096 else { return false }
    let data = Data(bytes.prefix(n))
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(raw.keys) == Set(["version", "kind", "id", "session", "occurredAt", "model", "source", "tokens"]),
      let rawTokens = raw["tokens"] as? [String: Any], Set(rawTokens.keys) == Set(["input", "output", "cacheRead", "cacheWrite"]),
      let entry = try? JSONDecoder().decode(DiskUsageEntry.self, from: data),
      entry.version == 1, entry.kind == "usage", entry.source == "pi.assistant.final",
      entry.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      entry.id + ".json" == file.lastPathComponent,
      entry.session.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      entry.model.range(of: "^[A-Za-z0-9._:/+@ -]{1,128}$", options: .regularExpression) != nil,
      entry.occurredAt >= 946684800000, entry.occurredAt <= Int64(Date().timeIntervalSince1970 * 1000),
      [entry.tokens.input, entry.tokens.output, entry.tokens.cacheRead, entry.tokens.cacheWrite].allSatisfy({ $0 == nil || ($0! >= 0 && $0! <= 9_007_199_254_740_991) }) else { return false }
    let children = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    var matches: [URL] = []
    for child in children.prefix(1024) where child.lastPathComponent.range(of: "^\\.usage-[0-9a-fA-F-]{36}$", options: .regularExpression) != nil {
      guard UUID(uuidString: String(child.lastPathComponent.dropFirst(7))) != nil else { continue }
      let other = open(child.path, O_RDONLY | O_NOFOLLOW)
      guard other >= 0 else { continue }
      var info = stat()
      if fstat(other, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == final.st_uid,
        info.st_mode & 0o077 == 0, info.st_nlink == 2, info.st_ino == final.st_ino, info.st_dev == final.st_dev, info.st_size == final.st_size {
        var temp = [UInt8](repeating: 0, count: 4097)
        let count = Darwin.read(other, &temp, temp.count)
        if count == n, SHA256.hash(data: Data(temp.prefix(count))) == SHA256.hash(data: data) { matches.append(child) }
      }
      Darwin.close(other)
    }
    guard matches.count == 1 else { return false }
    var latest = stat(), tempInfo = stat()
    guard lstat(file.path, &latest) == 0, lstat(matches[0].path, &tempInfo) == 0,
      latest.st_nlink == 2, tempInfo.st_nlink == 2, latest.st_ino == final.st_ino, tempInfo.st_ino == final.st_ino,
      latest.st_dev == final.st_dev, tempInfo.st_dev == final.st_dev else { return false }
    guard unlink(matches[0].path) == 0 else { return false }
    let d = open(dir.path, O_RDONLY | O_NOFOLLOW)
    if d >= 0 { _ = fsync(d); Darwin.close(d) }
    return true
  }
  private final class Database {
    let root: URL
    var handle: OpaquePointer?
    init(root: URL) throws {
      self.root = root
      for name in ["spool", "recorders"] { try UsageLedger.secureDirectory(root.appendingPathComponent(name)) }
      let path = root.appendingPathComponent("usage.sqlite3").path
      for suffix in ["", "-wal", "-shm"] {
        var info = stat()
        if lstat(path + suffix, &info) == 0 {
          guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
            info.st_mode & 0o077 == 0 else { throw LedgerError.unsafeStorage }
        } else if errno != ENOENT { throw LedgerError.unsafeStorage }
      }
      let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw LedgerError.unsafeStorage }; Darwin.close(fd)
      var db: OpaquePointer?
      guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }; throw LedgerError.databaseUnavailable
      }
      handle = db
      sqlite3_busy_timeout(db, 1500)
      do {
        let version = try scalar("PRAGMA user_version"), application = try scalar("PRAGMA application_id")
        let tables = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'")
        guard (version == 0 && application == 0 && tables == 0) || (version == 1 && application == 1346978901) else { throw LedgerError.incompatibleSchema }
        let check = try prepare("PRAGMA quick_check(1)")
        let healthy = sqlite3_step(check) == SQLITE_ROW && string(check, 0) == "ok"
        sqlite3_finalize(check)
        guard healthy else { throw LedgerError.databaseUnavailable }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        try exec("""
          CREATE TABLE IF NOT EXISTS usage_entries(id TEXT PRIMARY KEY, session TEXT NOT NULL, occurred INTEGER NOT NULL,
            model TEXT NOT NULL, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER);
          CREATE INDEX IF NOT EXISTS usage_time ON usage_entries(occurred);
          CREATE TABLE IF NOT EXISTS usage_conflicts(id TEXT PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS usage_meta(key TEXT PRIMARY KEY,value INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS usage_provenance(id TEXT PRIMARY KEY,origin TEXT NOT NULL,import_id TEXT NOT NULL,kind TEXT NOT NULL,coverage TEXT NOT NULL,has_realtime INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS history_imports(import_id TEXT PRIMARY KEY,source_set_hash TEXT NOT NULL,applied INTEGER NOT NULL,status TEXT NOT NULL,summary_json TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS usage_aliases(alias_id TEXT PRIMARY KEY,canonical_id TEXT NOT NULL,fingerprint TEXT NOT NULL,kind TEXT NOT NULL,import_id TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS history_conflicts(id TEXT NOT NULL,import_id TEXT NOT NULL,reason TEXT NOT NULL,PRIMARY KEY(id,import_id));
          PRAGMA user_version=1; PRAGMA application_id=1346978901;
          """)
      } catch { sqlite3_close(db); handle = nil; throw error }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func exec(_ sql: String) throws {
      guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw LedgerError.databaseUnavailable }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LedgerError.databaseUnavailable }
      return statement
    }
    func scalar(_ sql: String) throws -> Int64 {
      let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw LedgerError.databaseUnavailable }
      return sqlite3_column_int64(statement, 0)
    }
    func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) {
      sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    func bind(_ value: Int64?, _ statement: OpaquePointer, _ index: Int32) {
      if let value { sqlite3_bind_int64(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }
    func string(_ statement: OpaquePointer, _ index: Int32) -> String {
      sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }
    func int(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
      sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }
    func spoolFiles() throws -> [URL] {
      let spool = root.appendingPathComponent("spool")
      let shards = try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      var result: [URL] = []
      for shard in shards.prefix(256) where shard.lastPathComponent.range(of: "^[a-f0-9]{2}$", options: .regularExpression) != nil {
        try UsageLedger.secureDirectory(shard)
        let files = try FileManager.default.contentsOfDirectory(at: shard, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        result += files.filter { $0.pathExtension == "json" }.prefix(512)
      }
      return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func importSpool() throws -> (pending: Int, malformed: Int, conflicts: Int, reasons: [String]) {
      let files = try spoolFiles()
      if files.isEmpty {
        let status = try recorderStatus()
        return (0, status.malformed, Int(try scalar("SELECT count(*) FROM usage_conflicts")), Array(status.reasons))
      }
      let cursor = files.isEmpty ? 0 : Int(try scalar("SELECT COALESCE((SELECT value FROM usage_meta WHERE key='scan-cursor'),0)")) % files.count
      let batch = Array((Array(files.dropFirst(cursor)) + Array(files.prefix(cursor))).prefix(1024))
      var malformed = 0, reasons = Set<String>(), accepted: [(URL, Data)] = []
      try exec("BEGIN IMMEDIATE")
      do {
        for file in batch {
          _ = try? UsageLedger.recoverOwnPublishLink(file)
          let data: Data
          do { data = try UsageLedger.readPrivate(file) }
          catch LedgerError.fileMissing { continue }
          catch { malformed += 1; reasons.insert("坏记录保留待诊断"); continue }
          guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(raw.keys) == Set(["version", "kind", "id", "session", "occurredAt", "model", "source", "tokens"]),
            let rawTokens = raw["tokens"] as? [String: Any], Set(rawTokens.keys) == Set(["input", "output", "cacheRead", "cacheWrite"]),
            let entry = try? JSONDecoder().decode(DiskUsageEntry.self, from: data),
            entry.version == 1, entry.kind == "usage", entry.source == "pi.assistant.final",
            entry.id + ".json" == file.lastPathComponent,
            entry.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
            entry.session.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
            entry.occurredAt >= 946684800000, entry.occurredAt <= Int64(Date().timeIntervalSince1970 * 1000),
            entry.model.range(of: "^[A-Za-z0-9._:/+@ -]{1,128}$", options: .regularExpression) != nil,
            [entry.tokens.input, entry.tokens.output, entry.tokens.cacheRead, entry.tokens.cacheWrite].allSatisfy({
              $0 == nil || ($0! >= 0 && $0! <= 9_007_199_254_740_991)
            }) else { malformed += 1; reasons.insert("坏记录保留待诊断"); continue }
          if try acceptKnownAlias(entry) { accepted.append((file,data)); continue }
          let statement = try prepare("INSERT OR IGNORE INTO usage_entries VALUES(?,?,?,?,?,?,?,?)")
          defer { sqlite3_finalize(statement) }
          bind(entry.id, statement, 1); bind(entry.session, statement, 2); bind(entry.occurredAt, statement, 3)
          bind(entry.model, statement, 4); bind(entry.tokens.input, statement, 5); bind(entry.tokens.output, statement, 6)
          bind(entry.tokens.cacheRead, statement, 7); bind(entry.tokens.cacheWrite, statement, 8)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw LedgerError.databaseUnavailable }
          if sqlite3_changes(handle) == 0 {
            if try conflict(entry) { reasons.insert("重复receipt内容冲突") }
            else { try markRealtimeReceipt(entry.id) }
          }
          accepted.append((file, data))
        }
        let next = files.isEmpty ? 0 : (cursor + batch.count) % files.count
        try exec("INSERT OR REPLACE INTO usage_meta(key,value) VALUES('scan-cursor',\(next))")
        try exec("COMMIT")
      } catch { try? exec("ROLLBACK"); throw error }
      // A committed unique row is the durable acknowledgement. Re-import after any crash is idempotent.
      for (file, bytes) in accepted where (try? UsageLedger.readPrivate(file)) == bytes { _ = unlink(file.path) }
      let recorders = try recorderStatus()
      reasons.formUnion(recorders.reasons)
      if files.count > 1024 { reasons.insert("尚有记录等待索引") }
      return (max(0, files.count - accepted.count), malformed + recorders.malformed,
        Int(try scalar("SELECT count(*) FROM usage_conflicts")), Array(reasons))
    }
    private func markRealtimeReceipt(_ id: String) throws {
      let s=try prepare("UPDATE usage_provenance SET has_realtime=1 WHERE id=?")
      defer { sqlite3_finalize(s) };bind(id,s,1)
      guard sqlite3_step(s)==SQLITE_DONE else { throw LedgerError.databaseUnavailable }
    }
    private func acceptKnownAlias(_ entry: DiskUsageEntry) throws -> Bool {
      let s=try prepare("SELECT e.id,e.occurred,e.model,e.input,e.output,e.cache_read,e.cache_write FROM usage_aliases a JOIN usage_entries e ON e.id=a.canonical_id WHERE a.alias_id=?")
      defer { sqlite3_finalize(s) };bind(entry.id,s,1)
      guard sqlite3_step(s)==SQLITE_ROW else { return false }
      let same=int(s,1)==entry.occurredAt && string(s,2)==entry.model && int(s,3)==entry.tokens.input && int(s,4)==entry.tokens.output && int(s,5)==entry.tokens.cacheRead && int(s,6)==entry.tokens.cacheWrite
      if same { try markRealtimeReceipt(string(s,0)); return true }
      let c=try prepare("INSERT OR IGNORE INTO usage_conflicts VALUES(?)");defer { sqlite3_finalize(c) };bind(entry.id,c,1)
      guard sqlite3_step(c)==SQLITE_DONE else { throw LedgerError.databaseUnavailable };return true
    }
    private func conflict(_ entry: DiskUsageEntry) throws -> Bool {
      let s = try prepare("SELECT session,occurred,model,input,output,cache_read,cache_write FROM usage_entries WHERE id=?")
      defer { sqlite3_finalize(s) }; bind(entry.id, s, 1)
      guard sqlite3_step(s) == SQLITE_ROW else { throw LedgerError.databaseUnavailable }
      let same = string(s, 0) == entry.session && int(s, 1) == entry.occurredAt && string(s, 2) == entry.model
        && int(s, 3) == entry.tokens.input && int(s, 4) == entry.tokens.output
        && int(s, 5) == entry.tokens.cacheRead && int(s, 6) == entry.tokens.cacheWrite
      if !same {
        let c = try prepare("INSERT OR IGNORE INTO usage_conflicts VALUES(?)"); defer { sqlite3_finalize(c) }
        bind(entry.id, c, 1); guard sqlite3_step(c) == SQLITE_DONE else { throw LedgerError.databaseUnavailable }
      }
      return !same
    }
    private func recorderStatus() throws -> (reasons: Set<String>, malformed: Int) {
      let dir = root.appendingPathComponent("recorders")
      let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      var reasons = Set<String>(), malformed = 0
      for file in files.prefix(4096) where file.pathExtension == "json" {
        guard let data = try? UsageLedger.readPrivate(file), let value = try? JSONDecoder().decode(DiskRecorder.self, from: data),
          value.version == 1, value.kind == "recorder" else { malformed += 1; reasons.insert("记录器状态不可读"); continue }
        if value.dropped > 0 { reasons.insert("记录队列曾丢弃，当前为已知下界") }
        if value.pending > 0 { reasons.insert("Pi仍有记录待落盘") }
        if value.writeFailures > 0 { reasons.insert("记录器曾写盘失败，覆盖不完整") }
        for reason in value.reasons where reason != "auxiliary-usage-not-covered" { reasons.insert(Self.reasonText(reason)) }
      }
      if files.count > 4096 { reasons.insert("部分记录器状态未加载") }
      return (reasons, malformed)
    }
    static func reasonText(_ reason: String) -> String {
      switch reason {
      case "tool-usage-unattributed": return "工具聚合归属不足，未重复加总"
      case "boundary-usage-not-covered": return "压缩/摘要附加用量未覆盖"
      case "missing-usage": return "部分用量字段缺失，保留已知下界"
      case "receipt-conflict": return "重复receipt内容冲突"
      case "invalid-time": return "部分记录缺少有效消费时间"
      case "queue-full", "storage-capacity": return "记录存储达到上限，覆盖不完整"
      case "write-failed": return "Pi用量记录曾写盘失败"
      default: return "部分来源覆盖不完整"
      }
    }
    private(set) var lastAggregateRows = 0
    private var aggregateCaches: [UsageDateRange: (version: Int64, cursor: Int64, value: UsageAggregate, days: [Date: UsageTokenTotals])] = [:]
    private var rangeOrder: [UsageDateRange] = []
    private var coverageCache: (version: Int64, cursor: Int64, values: [String: Date])?
    func aggregate(range: UsageDateRange) throws -> UsageAggregate {
      let version = try scalar("PRAGMA data_version")
      let maximum = try scalar("SELECT COALESCE(max(rowid),0) FROM usage_entries")
      let cached = aggregateCaches[range]
      let reusable = cached.map { $0.version == version && $0.cursor <= maximum } ?? false
      var result = reusable ? cached!.value : UsageAggregate(range: range, timeZoneID: range.timeZone.identifier)
      let cursor = reusable ? cached!.cursor : 0
      var aggregateDays = reusable ? cached!.days : [:]
      var modelTotals = Dictionary(uniqueKeysWithValues: result.models.map { ($0.model, $0.tokens) })
      let visible = Set(range.days)
      var processed = 0
      if cursor < maximum {
        let statement = try prepare("SELECT e.rowid,e.occurred,e.model,e.input,e.output,e.cache_read,e.cache_write,COALESCE(p.origin,'realtime') FROM usage_entries e LEFT JOIN usage_provenance p ON p.id=e.id WHERE e.rowid>? AND e.occurred>=? AND e.occurred<? AND NOT EXISTS(SELECT 1 FROM usage_aliases a JOIN usage_entries canonical ON canonical.id=a.canonical_id WHERE a.alias_id=e.id) ORDER BY e.rowid")
        defer { sqlite3_finalize(statement) }
        bind(cursor, statement, 1)
        bind(Int64(range.start.timeIntervalSince1970 * 1000), statement, 2)
        bind(min(Int64(range.end.timeIntervalSince1970 * 1000), Int64(Date().timeIntervalSince1970 * 1000) + 1), statement, 3)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
          let date = Date(timeIntervalSince1970: Double(int(statement, 1) ?? 0) / 1000)
          let day = range.bucket(for: date), rawModel = string(statement, 2)
          let model = modelTotals[rawModel] != nil || modelTotals.count < 128 ? rawModel : "其他模型"
          let a = int(statement, 3), b = int(statement, 4), c = int(statement, 5), d = int(statement, 6)
          result.totals.add(input: a, output: b, cacheRead: c, cacheWrite: d)
          var total = modelTotals[model] ?? UsageTokenTotals(); total.add(input: a, output: b, cacheRead: c, cacheWrite: d); modelTotals[model] = total
          result.modelRecordCounts[model, default: 0] += 1
          let origin=string(statement,7)=="history" ? "history" : "realtime"
          var originTotal=result.originTotals[origin] ?? UsageTokenTotals();originTotal.add(input:a,output:b,cacheRead:c,cacheWrite:d);result.originTotals[origin]=originTotal
          result.originCounts[origin,default:0] += 1
          var om=result.originModels[origin]?[model] ?? UsageTokenTotals();om.add(input:a,output:b,cacheRead:c,cacheWrite:d);result.originModels[origin,default:[:]][model]=om
          result.originModelCounts[origin,default:[:]][model,default:0] += 1
          if visible.contains(day) {
            var od=result.originBuckets[origin]?[day] ?? UsageTokenTotals();od.add(input:a,output:b,cacheRead:c,cacheWrite:d);result.originBuckets[origin,default:[:]][day]=od
            var omd=result.originModelBuckets[origin]?[model]?[day] ?? UsageTokenTotals();omd.add(input:a,output:b,cacheRead:c,cacheWrite:d);result.originModelBuckets[origin,default:[:]][model,default:[:]][day]=omd
            var daily = aggregateDays[day] ?? UsageTokenTotals(); daily.add(input: a, output: b, cacheRead: c, cacheWrite: d); aggregateDays[day] = daily
            var md = result.modelBuckets[model]?[day] ?? UsageTokenTotals(); md.add(input: a, output: b, cacheRead: c, cacheWrite: d); result.modelBuckets[model, default: [:]][day] = md
          }
          result.recordCount += 1; processed += 1
          step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw LedgerError.databaseUnavailable }
      }
      let coverageReusable = coverageCache.map { $0.version == version && $0.cursor <= maximum } ?? false
      var firstDates = coverageReusable ? coverageCache!.values : [:]
      let coverageCursor = coverageReusable ? coverageCache!.cursor : 0
      if coverageCursor < maximum {
        let first = try prepare("SELECT COALESCE(p.origin,'realtime'),min(e.occurred) FROM usage_entries e LEFT JOIN usage_provenance p ON p.id=e.id WHERE e.rowid>? AND NOT EXISTS(SELECT 1 FROM usage_aliases a JOIN usage_entries canonical ON canonical.id=a.canonical_id WHERE a.alias_id=e.id) GROUP BY COALESCE(p.origin,'realtime')")
        defer { sqlite3_finalize(first) }; bind(coverageCursor, first, 1)
        var step = sqlite3_step(first)
        while step == SQLITE_ROW {
          let origin = string(first, 0) == "history" ? "history" : "realtime"
          let date = Date(timeIntervalSince1970: Double(int(first, 1) ?? 0) / 1000)
          firstDates[origin] = min(firstDates[origin] ?? date, date)
          step = sqlite3_step(first)
        }
        guard step == SQLITE_DONE else { throw LedgerError.databaseUnavailable }
      }
      coverageCache = (version, maximum, firstDates)
      result.originCollectedSince = firstDates
      result.collectedSince = firstDates.values.min()
      result.models = modelTotals.map { UsageModelTotal(model: $0.key, tokens: $0.value) }.sorted { $0.tokens.totalLowerBound > $1.tokens.totalLowerBound }
      result.availableModels = result.models.map(\.model).sorted()
      let currentBucket = range.bucket(for: Date())
      result.buckets = range.days.map { day in UsageBucket(day: day, state: day > currentBucket ? .future : (aggregateDays[day] == nil ? .uncollected : .data), tokens: aggregateDays[day] ?? UsageTokenTotals()) }
      result.historyReasons = []; result.historyImportedAt = nil; result.historyMinDate = nil; result.historyMaxDate = nil
      let history=try prepare("SELECT applied,summary_json FROM history_imports WHERE status='applied' ORDER BY applied DESC LIMIT 1")
      if sqlite3_step(history)==SQLITE_ROW {
        result.historyImportedAt=Date(timeIntervalSince1970:Double(int(history,0) ?? 0)/1000)
        if let data=string(history,1).data(using:.utf8),let receipt=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
          if let minimum=receipt["minUTCms"] as? Double { result.historyMinDate=Date(timeIntervalSince1970:minimum/1000) }
          if let maximum=receipt["maxUTCms"] as? Double { result.historyMaxDate=Date(timeIntervalSince1970:maximum/1000) }
          if let coverage=receipt["coverage"] as? [String:Int] {
            if (coverage["non-pi-or-unsupported-header"] ?? 0)>0 { result.historyReasons.append("非Pi SessionHeader格式的旁路JSONL未纳入") }
            if (coverage["ambiguous-candidates"] ?? 0)>0 { result.historyReasons.append("父链缺失/冲突继承项保守跳过") }
            for (key, label) in [
              ("usage-not-provided", "旧记录未提供usage"), ("summary-model-unknown", "压缩/摘要物理模型未知"),
              ("oversized-lines", "超出单行上限"), ("malformed-lines", "不可解析记录"),
              ("incomplete-tail", "未完成的文件尾"), ("missing-stable-entry-id", "缺稳定消费ID"),
              ("missing-valid-occurrence", "缺有效消费时间")
            ] { if let count = coverage[key], count > 0 { result.historyReasons.append("\(label)：\(count)项，未猜测或补0") } }
          }
          if let conflicts = receipt["conflicts"] as? Int, conflicts > 0 { result.historyReasons.append("导入内容冲突：\(conflicts)项，保留原记录") }
        }
      }
      sqlite3_finalize(history)
      result.coverageReasons = ["实时final与用户授权的一次性历史补采按同一消费键去重；owner累计/工具聚合不拼入"] + result.historyReasons
      if result.totals.overflow { result.coverageReasons.append("计数超出安全范围，仅显示已知下界") }
      if !result.totals.seen { result.coverageReasons.append("该时间范围尚未采集用量，不代表零消费") }
      lastAggregateRows = processed
      aggregateCaches[range] = (version, maximum, result, aggregateDays)
      rangeOrder.removeAll { $0 == range }; rangeOrder.append(range)
      if rangeOrder.count > 3 { aggregateCaches.removeValue(forKey: rangeOrder.removeFirst()) }
      return result
    }
  }
}
private extension UsageDateRange {
  var timeZoneCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }
}
