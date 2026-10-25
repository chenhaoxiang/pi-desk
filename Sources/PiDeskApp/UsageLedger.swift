import Darwin
import Foundation
import SQLite3

public enum UsagePreset: String, CaseIterable, Identifiable {
  case today = "今日"
  case last7 = "近7天"
  case month = "本月"
  case custom = "自定义"
  public var id: String { rawValue }
}

public struct UsageDateRange: Equatable {
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
  public var recordCount = 0
  public var collectedSince: Date?
  public var pendingRecords = 0
  public var conflicts = 0
  public var malformed = 0
  public var coverageReasons: [String] = []
  public var error: String?
  public var refreshedAt: Date?

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
            result.recordCount += 1
          }
        }
      }
      result.buckets = range.days.map { date in
        UsageBucket(day: date, state: date > range.bucket(for: now) ? .future : (byBucket[date] == nil ? .uncollected : .data), tokens: byBucket[date] ?? UsageTokenTotals())
      }
      result.models = byModel.map { UsageModelTotal(model: $0.key, tokens: $0.value) }.sorted { $0.tokens.totalLowerBound > $1.tokens.totalLowerBound }
      result.collectedSince = calendar.date(byAdding: .day, value: -5, to: today)
      result.coverageReasons = ["纯合成预览；工具/子任务附加量可能未覆盖"]
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
}

public final class UsageLedger: UsageLedgerClient {
  private let queue = DispatchQueue(label: "io.github.chenhaoxiang.pi-desk.usage-ledger", qos: .utility)
  private let root: URL
  private var request = 0

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

  public func refresh(
    range: UsageDateRange, completion: @escaping (UsageAggregate) -> Void
  ) {
    request += 1
    let requestID = request
    queue.async { [root] in
      let result = Self.read(root: root, range: range)
      DispatchQueue.main.async {
        guard requestID == self.request else { return }
        completion(result)
      }
    }
  }

  private static func read(root: URL, range: UsageDateRange) -> UsageAggregate {
    do {
      try secureDirectory(root)
      let db = try Database(root: root)
      let importResult = try db.importSpool()
      var aggregate = try db.aggregate(range: range)
      aggregate.pendingRecords = importResult.pending
      aggregate.malformed = importResult.malformed
      aggregate.conflicts = importResult.conflicts
      if aggregate.conflicts > 0 { aggregate.coverageReasons.append("重复receipt内容冲突，保留首次记录") }
      aggregate.coverageReasons = Array(Set(aggregate.coverageReasons + importResult.reasons)).sorted()
      aggregate.refreshedAt = Date()
      return aggregate
    } catch {
      var aggregate = UsageAggregate.empty(range)
      aggregate.error = Self.errorText(error)
      aggregate.coverageReasons = ["本地用量索引不可用；旧数据未清空，Pi继续独立运行"]
      aggregate.refreshedAt = Date()
      return aggregate
    }
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
  public static func inspect(root: URL, range: UsageDateRange) -> UsageAggregate { read(root: root, range: range) }
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
      let cursor = files.isEmpty ? 0 : Int(try scalar("SELECT COALESCE((SELECT value FROM usage_meta WHERE key='scan-cursor'),0)")) % files.count
      let batch = Array((Array(files.dropFirst(cursor)) + Array(files.prefix(cursor))).prefix(1024))
      var malformed = 0, reasons = Set<String>(), accepted: [(URL, Data)] = []
      try exec("BEGIN IMMEDIATE")
      do {
        for file in batch {
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
          let statement = try prepare("INSERT OR IGNORE INTO usage_entries VALUES(?,?,?,?,?,?,?,?)")
          defer { sqlite3_finalize(statement) }
          bind(entry.id, statement, 1); bind(entry.session, statement, 2); bind(entry.occurredAt, statement, 3)
          bind(entry.model, statement, 4); bind(entry.tokens.input, statement, 5); bind(entry.tokens.output, statement, 6)
          bind(entry.tokens.cacheRead, statement, 7); bind(entry.tokens.cacheWrite, statement, 8)
          guard sqlite3_step(statement) == SQLITE_DONE else { throw LedgerError.databaseUnavailable }
          if sqlite3_changes(handle) == 0 {
            if try conflict(entry) { reasons.insert("重复receipt内容冲突") }
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
    func aggregate(range: UsageDateRange) throws -> UsageAggregate {
      let s = try prepare("SELECT occurred,model,input,output,cache_read,cache_write FROM usage_entries WHERE occurred>=? AND occurred<? ORDER BY occurred,id LIMIT 500001")
      defer { sqlite3_finalize(s) }
      bind(Int64(range.start.timeIntervalSince1970 * 1000), s, 1)
      // The selected interval remains half-open; clipping a future end to now never includes a future record.
      bind(min(Int64(range.end.timeIntervalSince1970 * 1000), Int64(Date().timeIntervalSince1970 * 1000)), s, 2)
      var result = UsageAggregate(range: range, timeZoneID: range.timeZone.identifier)
      var byDay: [Date: UsageTokenTotals] = [:], byModel: [String: UsageTokenTotals] = [:]
      var step = sqlite3_step(s)
      while step == SQLITE_ROW {
        guard result.recordCount < 500000 else { result.coverageReasons.append("范围记录过多，请缩小时间范围；当前显示下界"); break }
        let date = Date(timeIntervalSince1970: Double(int(s, 0) ?? 0) / 1000)
        let day = range.bucket(for: date), model = string(s, 1)
        let a = int(s, 2), b = int(s, 3), c = int(s, 4), d = int(s, 5)
        result.totals.add(input: a, output: b, cacheRead: c, cacheWrite: d)
        var dayTotal = byDay[day] ?? UsageTokenTotals(); dayTotal.add(input: a, output: b, cacheRead: c, cacheWrite: d); byDay[day] = dayTotal
        let modelKey = byModel[model] != nil || byModel.count < 128 ? model : "其他模型"
        var modelTotal = byModel[modelKey] ?? UsageTokenTotals(); modelTotal.add(input: a, output: b, cacheRead: c, cacheWrite: d); byModel[modelKey] = modelTotal
        result.recordCount += 1
        step = sqlite3_step(s)
      }
      guard step == SQLITE_DONE || result.recordCount == 500000 else { throw LedgerError.databaseUnavailable }
      let earliest = try scalar("SELECT COALESCE(min(occurred),0) FROM usage_entries")
      if earliest > 0 { result.collectedSince = Date(timeIntervalSince1970: Double(earliest) / 1000) }
      result.models = byModel.map { UsageModelTotal(model: $0.key, tokens: $0.value) }.sorted { $0.tokens.totalLowerBound > $1.tokens.totalLowerBound }
      let currentBucket = range.bucket(for: Date())
      result.buckets = range.days.map { day in
        UsageBucket(day: day, state: day > currentBucket ? .future : (byDay[day] == nil ? .uncollected : .data), tokens: byDay[day] ?? UsageTokenTotals())
      }
      if range.days.last.map({ range.timeZoneCalendar.date(byAdding: range.hourly ? .hour : .day, value: 1, to: $0)! < range.end }) == true {
        result.coverageReasons.append("图表最多显示400个桶；总量仍覆盖所选范围")
      }
      result.coverageReasons += ["仅含启用采集后的Pi assistant final；工具/子任务附加量可能未覆盖"]
      if result.totals.overflow { result.coverageReasons.append("计数超出安全范围，仅显示已知下界") }
      if !result.totals.seen { result.coverageReasons.append("该时间范围尚未采集用量，不代表零消费") }
      return result
    }
  }
}
private extension UsageDateRange {
  var timeZoneCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }
}
