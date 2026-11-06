import Foundation

public struct IntercomRelations: Codable, Equatable, Sendable {
  public var version: Int
  public var senderSessionId: String
  public var recipientSessionId: String
  public var supersedes: String?
  public var supersededBy: String?
  public var replyTo: String?
  public var lateReplyTo: String?
  public var replyCorrelation: String
  private static func alphanumeric(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
  public static func safeId(_ value: String) -> Bool {
    value.utf8.count <= 128 && !value.contains("..") && !AssistantPrivacy.sensitive(value)
      && value.utf8.first.map(alphanumeric) == true
      && value.utf8.allSatisfy { alphanumeric($0) || [46,95,45,58].contains($0) }
  }
  public var valid: Bool {
    version == 1 && Self.safeId(senderSessionId) && Self.safeId(recipientSessionId)
      && [supersedes,supersededBy,replyTo,lateReplyTo].compactMap { $0 }.allSatisfy(Self.safeId)
      && ["none","matched","late","unknown"].contains(replyCorrelation)
      && !(replyTo != nil && lateReplyTo != nil)
      && (replyCorrelation != "matched" || replyTo != nil)
      && (replyCorrelation != "late" || lateReplyTo != nil)
      && (replyCorrelation != "none" || (replyTo == nil && lateReplyTo == nil))
  }
  public var summary: String {
    switch replyCorrelation {
    case "matched": return "原回复关联已匹配，不代表业务批准"
    case "late": return "迟到回复：未匹配当前回复等待"
    case "none": return "非回复消息，不代表业务尚未答复"
    default: return "原回复关联未知，不推断是否有效"
    }
  }
}
public struct IntercomStatusView: Codable, Equatable, Identifiable, Sendable {
  public var messageId: String
  public var observedAt: Double
  public var sourceUpdatedAt: Double?
  public var coverage: String
  public var reason: String?
  public var delivery: String?
  public var replyState: String?
  public var outcomeKnown: Bool?
  public var relations: IntercomRelations?
  public var id: String { messageId }
  public var valid: Bool {
    guard IntercomRelations.safeId(messageId), MissionDecisionRow.time(observedAt), sourceUpdatedAt == nil || MissionDecisionRow.time(sourceUpdatedAt!) else { return false }
    if coverage == "unavailable" { return reason.map(MissionDecisionRow.reference) == true && delivery == nil && replyState == nil && outcomeKnown == nil && relations == nil }
    guard coverage == "observed", reason == nil, sourceUpdatedAt != nil, let delivery, let replyState, let outcomeKnown, let relations, relations.valid else { return false }
    return ["socket_delivered","queued","failed","unknown"].contains(delivery)
      && ["not_requested","pending","answered","expired","unknown"].contains(replyState)
      && outcomeKnown == (delivery != "unknown")
      && (delivery != "unknown" || relations.replyCorrelation == "unknown")
      && ![relations.supersedes,relations.supersededBy,relations.replyTo,relations.lateReplyTo].contains(messageId)
  }
  public var replyTitle: String {
    switch replyState {
    case "pending": return "原回复等待仍在"
    case "answered": return "原回复等待已匹配"
    case "expired": return "原回复等待已关闭"
    case "not_requested": return "未请求回复"
    default: return "原回复等待未知"
    }
  }
  public var unavailableTitle: String { reason == "same-time-conflict" ? "原传输记录冲突，关联待核" : "原生关联未提供或不可用" }
}
public struct IntercomRelationsProjection: Codable, Equatable, Sendable {
  public var version: Int
  public var source: String
  public var scope: String
  public var observerSeq: Int
  public var coverage: String
  public var records: [IntercomStatusView]
  public var omitted: Int
  public var evictedRecords: Int
  public var valid: Bool {
    guard version == 1, source == "pi.intercom.status", MissionDecisionRow.reference(scope), (0...9_007_199_254_740_991).contains(observerSeq), ["not-observed","observed","partial"].contains(coverage), records.count <= 16, Set(records.map(\.id)).count == records.count, records.allSatisfy(\.valid), (0...16).contains(omitted), (0...9_007_199_254_740_991).contains(evictedRecords) else { return false }
    if coverage == "not-observed" { return records.isEmpty && omitted == 0 && evictedRecords == 0 }
    return coverage != "observed" || (omitted == 0 && evictedRecords == 0 && records.allSatisfy { $0.coverage == "observed" })
  }
}
