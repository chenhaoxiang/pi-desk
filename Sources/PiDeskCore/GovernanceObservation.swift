import Foundation

// Display-transport copies of public Pi Vista metadata. No task state or
// acceptance policy lives here; these checks only admit bounded wire data.
private func reference(_ value: String, max: Int = 128) -> Bool {
  !value.isEmpty && value.utf8.count <= max && value != "." && value != ".."
    && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
}
private let observationReferencePatterns: [NSRegularExpression] = [
  #"[\x00-\x1f\x7f-\x9f]"#, #"(?:^|[\\/])(?:Users|home|private|var|tmp|etc|opt|workspace|src)(?:[\\/]|$)|^[A-Za-z]:[\\/]"#, #"&&|\|\||[;`$<>]"#, #"://[^/\s:]+:[^@/\s]+@"#, #"(?i)(?:^|[^a-z0-9])(?:args?|argv|command|completion|content|cwd|directory|file(?:name|path)?|input|model|output|path|prompt|raw|request|response|secret|shell|stderr|stdin|stdout|token|credential|password)(?:$|[^a-z0-9])"#
].map { try! NSRegularExpression(pattern: $0) }
private func observationReference(_ value: String) -> Bool {
  guard !value.isEmpty, value.utf16.count <= 256, !AssistantPrivacy.sensitive(value) else { return false }
  let range = NSRange(value.startIndex..<value.endIndex, in: value)
  return observationReferencePatterns.allSatisfy { $0.firstMatch(in: value, range: range) == nil }
}
public struct PiWorkRef: Codable, Hashable, Sendable {
  public var owner: String
  public var kind: String
  public var key: String
  public var valid: Bool {
    owner.utf8.count <= 256 && (1...2).contains(owner.split(separator: "/", omittingEmptySubsequences: false).count)
      && owner.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { reference(String($0), max: 256) }
      && ["issue", "change", "task", "document"].contains(kind) && reference(key)
  }
  public var kindTitle: String { ["issue": "问题", "change": "变更", "task": "任务", "document": "文档"][kind] ?? "工作项" }
}
public struct PiWorkBinding: Codable, Hashable, Sendable {
  public var workRef: PiWorkRef
  public var stageId: String
  public var runId: String
  public var sessionId: String
  public var revision: Int
  public var headSha: String?
  public var valid: Bool {
    workRef.valid && [stageId, runId, sessionId].allSatisfy { reference($0) }
      && (0...9_007_199_254_740_991).contains(revision)
      && (headSha == nil || headSha!.range(of: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$", options: .regularExpression) != nil)
  }
  public var stageTitle: String {
    switch stageId {
    case "subagent-output-available": return "子任务产物"
    case "source-shared-delivery": return "源码交付"
    default: return stageId
    }
  }
}
public struct PiOwnerResult: Codable, Hashable, Sendable {
  public var binding: PiWorkBinding?
  public var resultRef: String?
  public var decision: String
  public var outcome: String
  public var reasonCode: String
  public var authorization: String
  public var readOnly: Bool
  public var valid: Bool {
    guard (binding == nil || binding!.valid), (resultRef == nil || reference(resultRef!)), reference(reasonCode), authorization == "none", readOnly else { return false }
    return (decision == "deliverable" && outcome == "accepted" && binding != nil && reasonCode == "owner_acceptance_confirmed")
      || (decision == "reportable_terminal" && outcome == "failed" && binding != nil)
      || (decision == "reconcile_required" && outcome == "unknown")
  }
  public var statusTitle: String {
    if decision == "reconcile_required" { return "待原 owner 对账" }
    if decision == "reportable_terminal" { return "原阶段未通过" }
    switch binding?.stageId {
    case "subagent-output-available": return "原 owner 记录：产物可用"
    case "source-shared-delivery": return "原 owner 记录：源码已交付"
    default: return "原 owner 记录：阶段可交付"
    }
  }
  public var scopeNote: String {
    switch binding?.stageId {
    case "subagent-output-available": return "只证明子任务产物可用；不代表任务验收或业务完成。"
    case "source-shared-delivery": return "只涉及该源码阶段；不代表已安装、运行或业务验收。"
    default: return "只适用于此 work/stage/run/revision；不替代其他阶段或业务验收。"
    }
  }
  public var reasonTitle: String {
    let labels = ["owner_acceptance_confirmed": "该阶段原 owner 验收已记录", "owner_outcome_unknown": "原 owner 结果未知", "owner_readback_not_current": "回读已过期或不在有效范围", "required_effect_pending": "必要效果尚在等待", "required_effect_unknown": "必要效果未知，需对账", "owner_reader_timeout": "原 owner 回读超时", "owner_reader_failed": "原 owner 回读不可用", "required_evidence_not_validated": "必要证据尚未验证", "required_evidence_conflict": "必要证据冲突", "owner_rejected": "原 owner 未接受此阶段", "required_effect_not_successful": "必要效果未成功"]
    return labels[reasonCode] ?? reasonCode
  }
}
public struct PiWorkHandoff: Codable, Hashable, Sendable {
  public var previous: PiWorkBinding?
  public var successor: PiWorkBinding?
  public var decision: String
  public var reasonCode: String
  public var acceptedFactRefs: [String]
  public var unresolvedEffectRefs: [String]
  public var blockerRefs: [String]
  public var nextAction: String
  public var sourceHeadRecheckRequired: Bool
  public var currentVerification: String
  public var authorization: String
  public var executable: Bool
  public var readOnly: Bool
  public var valid: Bool {
    guard (previous == nil || previous!.valid), (successor == nil || successor!.valid), ["handoff_observed", "reconcile_required"].contains(decision), reference(reasonCode), [acceptedFactRefs, unresolvedEffectRefs, blockerRefs].allSatisfy({ $0.count <= 64 && $0.allSatisfy { observationReference($0) } }), ["reconcile", "continue", "wait", "close", "handoff", "none"].contains(nextAction), sourceHeadRecheckRequired, currentVerification == "not_checked", authorization == "none", !executable, readOnly else { return false }
    if decision == "handoff_observed" {
      guard let previous, let successor else { return false }
      return reasonCode == "handoff_observed" && previous.workRef == successor.workRef && previous.stageId == successor.stageId && previous.runId != successor.runId && previous.sessionId != successor.sessionId
    }
    return true
  }
  public var nextActionTitle: String {
    ["reconcile": "对账", "continue": "继续", "wait": "等待", "close": "收尾", "handoff": "交接", "none": "无下一步建议"][nextAction] ?? "未知"
  }
}
public struct GovernanceObservedResult: Codable, Hashable, Sendable {
  public var seq: Int
  public var observedAt: Double
  public var observation: PiOwnerResult
  public var valid: Bool { seq > 0 && observedAt.isFinite && observedAt >= 0 && observedAt <= 7_258_118_400_000 && observedAt.rounded(.towardZero) == observedAt && observation.valid }
}
public struct GovernanceObservedHandoff: Codable, Hashable, Sendable {
  public var seq: Int
  public var observedAt: Double
  public var observation: PiWorkHandoff
  public var valid: Bool { seq > 0 && observedAt.isFinite && observedAt >= 0 && observedAt <= 7_258_118_400_000 && observedAt.rounded(.towardZero) == observedAt && observation.valid }
}
public struct GovernanceProjection: Codable, Equatable, Sendable {
  public var version: Int
  public var source: String
  public var coverage: String
  public var observerEpoch: String?
  public var observerSeq: Int?
  public var observedAt: Double?
  public var stale: Bool?
  public var results: [GovernanceObservedResult]
  public var handoffs: [GovernanceObservedHandoff]
  public var omittedObservations: Int
  public var omittedResults: Int
  public var omittedHandoffs: Int
  public var valid: Bool {
    guard version == 1, source == "pi.vista", ["not-observed", "not-applicable", "observed", "partial", "unavailable"].contains(coverage), results.count <= 16, handoffs.count <= 8, results.allSatisfy(\.valid), handoffs.allSatisfy(\.valid), [omittedObservations, omittedResults, omittedHandoffs].allSatisfy({ (0...9_007_199_254_740_991).contains($0) }) else { return false }
    if let observerEpoch, !reference(observerEpoch) { return false }
    if let observerSeq, !(0...9_007_199_254_740_991).contains(observerSeq) { return false }
    let sequences = results.map(\.seq) + handoffs.map(\.seq)
    if Set(sequences).count != sequences.count || sequences.contains(where: { $0 > (observerSeq ?? -1) }) { return false }
    if let observedAt, !observedAt.isFinite || observedAt < 0 || observedAt > 7_258_118_400_000 || observedAt.rounded(.towardZero) != observedAt { return false }
    if ["observed", "partial"].contains(coverage) { return observerEpoch != nil && observerSeq != nil && (coverage == "partial" || (omittedObservations == 0 && omittedResults == 0 && omittedHandoffs == 0)) }
    return results.isEmpty && handoffs.isEmpty && omittedObservations == 0 && omittedResults == 0 && omittedHandoffs == 0
  }
  public var coverageTitle: String {
    if stale == true { return "保留最后owner观察 · 最近读取未确认" }
    switch coverage {
    case "observed": return "已收到原 owner 观察"
    case "partial": return "部分 owner 观察"
    case "not-applicable": return "当前会话不在 owner 观察范围"
    case "not-observed": return "尚无工作结果观察"
    default: return "工作结果来源未接入或不可用"
    }
  }
}
public struct WorkResultEntry: Identifiable, Sendable {
  public var reporter: Identity
  public var connected: Bool
  public var observedAt: Double?
  public var result: PiOwnerResult
  public var id: String
  public var observerEpoch: String = "unprovided"
  public var sequence: Int = 0
}
public struct WorkHandoffEntry: Identifiable, Sendable {
  public var id: String
  public var reporter: Identity
  public var connected: Bool
  public var observedAt: Double
  public var handoff: PiWorkHandoff
  public var observerEpoch: String
  public var sequence: Int
}
public struct WorkInputEntry: Identifiable, Sendable {
  public var id: String
  public var reporter: Identity
  public var input: InputNotice
}
public struct WorkResultGroup: Identifiable, Sendable {
  public var id: PiWorkRef
  public var entries: [WorkResultEntry]
  public var decisions: [MissionDecisionEntry] = []
  public var progress: [WorkProgressEntry] = []
  public var handoffs: [WorkHandoffEntry] = []
  public var inputs: [WorkInputEntry] = []
}
public enum WorkResultPortfolio {
  /// Only explicit owner/kind/key can group observations. Reporting a child's
  /// result does not bind all tasks in the reporting session to that work.
  public static func groups(_ sessions: [SessionView]) -> [WorkResultGroup] {
    var result: [WorkResultGroup] = [], slots: [PiWorkRef: Int] = [:]
    for session in sessions {
      let projection = session.snapshot.governance
      for item in projection?.results ?? [] {
        let observation = item.observation
        guard let binding = observation.binding else { continue }
        let ref = binding.workRef
        let entry = WorkResultEntry(reporter: session.snapshot.identity, connected: session.connection == .connected && projection?.stale != true, observedAt: item.observedAt, result: observation, id: session.snapshot.identity.sessionKey + ":" + session.snapshot.identity.runtimeEpoch + ":" + (projection?.observerEpoch ?? "unknown") + ":" + String(item.seq), observerEpoch: projection?.observerEpoch ?? "unprovided", sequence: item.seq)
        if let index = slots[ref] { result[index].entries.append(entry) }
        else { slots[ref] = result.count; result.append(WorkResultGroup(id: ref, entries: [entry])) }
      }
      if let progress = session.snapshot.codeProgress, let epoch = progress.observerEpoch {
        for record in progress.observations {
          let ref = record.binding.workRef
          let entry = WorkProgressEntry(id: session.snapshot.identity.sessionKey + ":" + session.snapshot.identity.runtimeEpoch + ":" + epoch + ":p:" + String(record.seq), reporter: session.snapshot.identity, observerEpoch: epoch, connected: session.connection == .connected && progress.stale != true && progress.coverage == "observed", progress: record)
          if let index = slots[ref] { result[index].progress.append(entry) }
          else { slots[ref] = result.count; result.append(WorkResultGroup(id: ref, entries: [], progress: [entry])) }
        }
      }
      for item in projection?.handoffs ?? [] {
        let h = item.observation
        // A contradictory cross-work handoff remains visible in session detail,
        // never assigned to one guessed work card.
        guard let ref = h.successor?.workRef ?? h.previous?.workRef, h.previous == nil || h.successor == nil || h.previous!.workRef == h.successor!.workRef else { continue }
        let entry = WorkHandoffEntry(id: session.snapshot.identity.sessionKey + ":" + session.snapshot.identity.runtimeEpoch + ":" + (projection?.observerEpoch ?? "unprovided") + ":h:" + String(item.seq), reporter: session.snapshot.identity, connected: session.connection == .connected && projection?.stale != true, observedAt: item.observedAt, handoff: h, observerEpoch: projection?.observerEpoch ?? "unprovided", sequence: item.seq)
        if let index = slots[ref] { result[index].handoffs.append(entry) }
        else { slots[ref] = result.count; result.append(WorkResultGroup(id: ref, entries: [], handoffs: [entry])) }
      }
      if let decisions = session.snapshot.missionDecisions {
        for record in decisions.missions {
          let ref = record.workRef
          let entry = MissionDecisionEntry(id: session.snapshot.identity.sessionKey + ":" + session.snapshot.identity.runtimeEpoch + ":" + decisions.scope + ":" + ref.key, reporter: session.snapshot.identity, connected: session.connection == .connected, record: record)
          if let index = slots[ref] { result[index].decisions.append(entry) }
          else { slots[ref] = result.count; result.append(WorkResultGroup(id: ref, entries: [], decisions: [entry])) }
        }
      }
    }
    // Inputs may attach only by the original question producer's explicit
    // declared work reference. They never manufacture a new work/acceptance.
    for session in sessions where session.connection == .connected {
      for input in session.snapshot.inputs {
        guard input.kind == "question", let question = input.question, question.binding == "declared", let ref = question.workRef, let index = slots[ref] else { continue }
        result[index].inputs.append(WorkInputEntry(id: session.snapshot.identity.sessionKey + ":" + session.snapshot.identity.runtimeEpoch + ":" + input.id, reporter: session.snapshot.identity, input: input))
      }
    }
    return result
  }
}
