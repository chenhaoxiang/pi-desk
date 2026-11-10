import Foundation

public struct NativeSessionMeta: Codable, Equatable, Sendable {
  public var version: Int
  public var source: String
  public var scope: String
  public var coverage: String
  public var observedAt: Double?
  public var records: Int?
  public var scanned: Int?
  public var compactions: Int?
  public var lastActivityAt: Double?
  public var lastActivityKind: String?
  public var valid: Bool {
    guard version == 1, source == "pi.session-manager", scope == "current-session-records", ["not-observed","observed","partial","unavailable"].contains(coverage), observedAt == nil || MissionDecisionRow.time(observedAt!) else { return false }
    if coverage == "not-observed" || coverage == "unavailable" { return records == nil && scanned == nil && compactions == nil && lastActivityAt == nil && lastActivityKind == nil }
    guard observedAt != nil, let records, let scanned, let compactions, (0...9_007_199_254_740_991).contains(records), scanned >= 0, scanned <= records, (0...scanned).contains(compactions), coverage != "observed" || records == scanned else { return false }
    return (lastActivityAt == nil && lastActivityKind == nil) || (lastActivityAt.map(MissionDecisionRow.time) == true && ["message","compaction","branch_summary"].contains(lastActivityKind ?? ""))
  }
  public var compactionTitle: String {
    guard let compactions, ["observed","partial"].contains(coverage) else { return "压缩次数：尚未取得原生记录" }
    return "压缩记录：\(compactions) 次" + (coverage == "partial" ? "（已扫描下界）" : "（各分支，可能含继承）")
  }
}
