import Foundation

public struct MissionDecisionRow: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var status: String
  public var createdAt: Double
  public var resolvedAt: Double?
  public var valid: Bool {
    Self.identifier(id) && ["open", "resolved"].contains(status) && Self.time(createdAt) && (resolvedAt == nil || Self.time(resolvedAt!))
  }
  private static func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
  static func reference(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." && !AssistantPrivacy.sensitive(value)
      && value.utf8.allSatisfy { alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
  }
  static func identifier(_ value: String) -> Bool {
    reference(value) && !value.contains("..") && value.utf8.first.map(alphanumeric) == true
  }
  static func time(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 7_258_118_400_000 && value.rounded(.towardZero) == value }
  public var statusTitle: String { status == "open" ? "原记录未决" : "原记录已解决" }
}
public struct MissionDecisionCounts: Codable, Equatable, Sendable {
  public var open: Int
  public var resolved: Int
  public var total: Int
  public var valid: Bool { [open,resolved,total].allSatisfy { (0...512).contains($0) } && open + resolved == total }
}
public struct MissionDecisionView: Codable, Equatable, Sendable {
  public var workRef: PiWorkRef
  public var observedAt: Double
  public var sourceUpdatedAt: Double?
  public var coverage: String
  public var reason: String?
  public var counts: MissionDecisionCounts?
  public var decisions: [MissionDecisionRow]
  public var omitted: Int
  public var valid: Bool {
    guard workRef.valid, workRef.owner == "chenhaoxiang/pi-subagents", workRef.kind == "task", MissionDecisionRow.identifier(workRef.key), MissionDecisionRow.time(observedAt), sourceUpdatedAt == nil || MissionDecisionRow.time(sourceUpdatedAt!), decisions.count <= 32, Set(decisions.map(\.id)).count == decisions.count, decisions.allSatisfy(\.valid), (0...512).contains(omitted) else { return false }
    if coverage == "unavailable" { return counts == nil && decisions.isEmpty && omitted == 0 && reason.map(MissionDecisionRow.reference) == true }
    guard ["complete","partial"].contains(coverage), sourceUpdatedAt != nil, reason == nil, let counts, counts.valid, decisions.count + omitted == counts.total, coverage != "complete" || omitted == 0 else { return false }
    let open = decisions.filter { $0.status == "open" }.count
    return open <= counts.open && decisions.count - open <= counts.resolved
  }
  public var summary: String {
    guard let counts else { return reason == "same-time-conflict" ? "原记录有冲突，决策状态待核" : "决策记录不可用，不按零项处理" }
    if counts.total == 0 { return "本次原记录没有决策项" }
    return "原工作记录：\(counts.open) 项未决 · \(counts.resolved) 项已记录解决"
  }
  public var scopeNote: String {
    guard let counts else { return "缺失或冲突不代表已解决，请查看原 owner。" }
    return counts.open > 0 ? "仍有未决项；已解决的部分不代表全部问题已答复或用户批准。" : "仅表示这份原决策记录的状态，不代表用户批准、工作完成或没有其他问题。"
  }
}
public struct MissionDecisionsProjection: Codable, Equatable, Sendable {
  public var version: Int
  public var source: String
  public var scope: String
  public var observerSeq: Int
  public var coverage: String
  public var missions: [MissionDecisionView]
  public var omittedMissions: Int
  public var evictedRecords: Int
  public var valid: Bool {
    guard version == 1, source == "pi.subagents.mission", MissionDecisionRow.reference(scope), (0...9_007_199_254_740_991).contains(observerSeq), ["not-observed","observed","partial","unavailable"].contains(coverage), missions.count <= 16, missions.allSatisfy(\.valid), Set(missions.map { $0.workRef.key }).count == missions.count, (0...9_007_199_254_740_991).contains(omittedMissions), (0...9_007_199_254_740_991).contains(evictedRecords) else { return false }
    if ["not-observed","unavailable"].contains(coverage) { return missions.isEmpty && omittedMissions == 0 && evictedRecords == 0 }
    return coverage != "observed" || (omittedMissions == 0 && evictedRecords == 0 && missions.allSatisfy { $0.coverage == "complete" })
  }
}
public struct MissionDecisionEntry: Identifiable, Sendable {
  public var id: String
  public var reporter: Identity
  public var connected: Bool
  public var record: MissionDecisionView
}
