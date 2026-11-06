import Foundation

public struct CodeProgressRow: Codable, Hashable, Sendable {
  public var seq: Int
  public var binding: PiWorkBinding
  public var repository: String
  public var pullRequest: Int
  public var observedAt: Double
  public var phase: String
  public var waitReason: String
  public var nextAction: String
  public var authorization: String
  public var readOnly: Bool
  public var executable: Bool
  private static let triples: Set<String> = [
    "pull-request/pr_not_ready/follow_owner_work",
    "head-checks/required_checks_pending/wait_required_checks",
    "head-checks/required_checks_failed/inspect_required_checks",
    "head-checks/required_checks_missing/inspect_required_evidence",
    "owner-gate/owner_delivery_pending/follow_owner_delivery",
    "postmerge-checks/postmerge_workflows_pending/wait_postmerge_checks",
    "postmerge-checks/postmerge_workflows_failed/inspect_postmerge_checks",
    "postmerge-checks/postmerge_workflows_missing/inspect_required_evidence",
    "owner-gate/owner_gate_unavailable/inspect_owner_evidence",
    "source-delivery/none/inspect_result",
    "unknown/source_binding_mismatch/inspect_binding",
    "unknown/source_original_unavailable/inspect_originals",
  ]
  private static let repositoryPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$")
  public static func validRepository(_ value: String) -> Bool {
    value.utf8.count <= 200 && !AssistantPrivacy.sensitive(value) && !value.hasSuffix("/.") && !value.hasSuffix("/..")
      && repositoryPattern.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex,in:value)) != nil
  }
  public var valid: Bool {
    (1...9_007_199_254_740_991).contains(seq) && binding.valid && binding.headSha != nil && Self.validRepository(repository)
      && (1...9_007_199_254_740_991).contains(pullRequest) && MissionDecisionRow.time(observedAt)
      && Self.triples.contains(phase + "/" + waitReason + "/" + nextAction)
      && authorization == "none" && readOnly && !executable
  }
  public var pullRequestURL: URL? { valid ? URL(string: "https://github.com/" + repository + "/pull/" + String(pullRequest)) : nil }
  public var phaseTitle: String {
    ["pull-request":"PR 准备", "head-checks":"提交检查", "owner-gate":"原负责人交付", "postmerge-checks":"合并后检查", "source-delivery":"源码交付观察", "unknown":"阶段待核"][phase] ?? "阶段未提供"
  }
  public var waitTitle: String {
    ["pr_not_ready":"PR 尚未达到原交付条件", "required_checks_pending":"等待该 head 的必要检查", "required_checks_failed":"该 head 的必要检查未通过", "required_checks_missing":"必要检查原件未提供", "owner_delivery_pending":"检查已有结果，等待原负责人交付", "postmerge_workflows_pending":"等待合并后的必要工作流", "postmerge_workflows_failed":"合并后的必要工作流未通过", "postmerge_workflows_missing":"合并后工作流原件未提供", "owner_gate_unavailable":"原 Gate 原件不可用", "none":"进度记录无等待项；已验范围另看原结果", "source_binding_mismatch":"原绑定或 head 不匹配，不能沿用为当前进度", "source_original_unavailable":"原始进度来源不可用"][waitReason] ?? "等待来源未提供"
  }
  public var nextActionTitle: String {
    ["follow_owner_work":"原负责人继续原工作", "wait_required_checks":"等待必要检查", "inspect_required_checks":"核对未通过的检查", "inspect_required_evidence":"核对缺失原件", "follow_owner_delivery":"原负责人完成交付步骤", "wait_postmerge_checks":"等待合并后检查", "inspect_postmerge_checks":"核对合并后检查", "inspect_owner_evidence":"核对原 Gate 证据", "inspect_result":"查看原阶段验收结果", "inspect_binding":"核对工作与 head 绑定", "inspect_originals":"核对原始来源"][nextAction] ?? "原下一步未提供"
  }
  public var hasSourceProblem: Bool { ["required_checks_failed","required_checks_missing","postmerge_workflows_failed","postmerge_workflows_missing","owner_gate_unavailable","source_binding_mismatch","source_original_unavailable"].contains(waitReason) }
}
public struct CodeProgressProjection: Codable, Equatable, Sendable {
  public var version: Int
  public var source: String
  public var seq: Int
  public var coverage: String
  public var observations: [CodeProgressRow]
  public var omitted: Int
  public var observerEpoch: String?
  public var stale: Bool?
  public var valid: Bool {
    guard version == 1, source == "explicit-code-owner", (0...9_007_199_254_740_991).contains(seq), ["not-observed","observed","not-applicable","unavailable"].contains(coverage), observations.count <= 16, observations.allSatisfy(\.valid), (0...9_007_199_254_740_991).contains(omitted), observerEpoch == nil || MissionDecisionRow.reference(observerEpoch!) else { return false }
    if ["not-observed","not-applicable"].contains(coverage) { return observations.isEmpty && omitted == 0 }
    guard observerEpoch != nil || (coverage == "unavailable" && observations.isEmpty) else { return false }
    var previous = 0
    for row in observations { if row.seq <= previous || row.seq > seq { return false }; previous = row.seq }
    var bounded = self; bounded.observerEpoch = nil; bounded.stale = nil
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let bytes = try? encoder.encode(bounded), bytes.count <= 5400 else { return false }
    return true
  }
  public var coverageTitle: String {
    if stale == true || (coverage == "unavailable" && !observations.isEmpty) { return "保留最后进度 · 最近读取未确认" }
    switch coverage {
    case "observed": return "原代码进度已提供"
    case "not-observed": return "原代码进度尚未采集"
    case "not-applicable": return "本来源不在代码进度观察范围"
    default: return "原代码进度未提供或不可用"
    }
  }
}
public struct WorkProgressEntry: Identifiable, Sendable {
  public var id: String
  public var reporter: Identity
  public var observerEpoch: String
  public var connected: Bool
  public var progress: CodeProgressRow
}
