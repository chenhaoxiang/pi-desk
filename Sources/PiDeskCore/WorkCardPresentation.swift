import Foundation

/// Display grouping only: a different reporter, epoch, run, revision, head or
/// stage always gets its own summary. Independent lanes never share sequences.
public struct WorkStageKey: Hashable, Sendable {
  public var reporter: Identity
  public var observerEpoch: String
  public var binding: PiWorkBinding
  public var repository: String? = nil
  public var pullRequest: Int? = nil
}
public struct WorkStageSummary: Identifiable, Sendable {
  public var id: WorkStageKey
  public var results: [WorkResultEntry] = []
  public var progress: [WorkProgressEntry] = []
  public var handoffs: [WorkHandoffEntry] = []
  public var latestHandoff: WorkHandoffEntry? { handoffs.max { $0.sequence < $1.sequence } }
  public var latestResult: WorkResultEntry? { results.max { $0.sequence < $1.sequence } }
  public var latestProgress: WorkProgressEntry? { progress.max { $0.progress.seq < $1.progress.seq } }
  public var historicalResults: [WorkResultEntry] { results.sorted { $0.sequence > $1.sequence }.dropFirst().map { $0 } }
  public var historicalProgress: [WorkProgressEntry] { progress.sorted { $0.progress.seq > $1.progress.seq }.dropFirst().map { $0 } }
  public var lastOriginalTime: Double { max(latestProgress?.progress.observedAt ?? 0, max(latestResult?.observedAt ?? 0, latestHandoff?.observedAt ?? 0)) }
  public var phaseTitle: String {
    guard let progress = latestProgress else { return id.binding.stageTitle }
    return (progress.connected ? "" : "进度待核 · ") + progress.progress.phaseTitle
  }
  public var waitTitle: String {
    guard let progress = latestProgress else { return "真实等待来源未提供" }
    return (progress.connected ? "" : "最后记录：") + progress.progress.waitTitle
  }
  public var nextTitle: String {
    if let progress = latestProgress { return progress.progress.nextActionTitle }
    if let handoff = latestHandoff { return "原交接建议：" + handoff.handoff.nextActionTitle + "（尚未重新核验）" }
    return "原下一步未提供"
  }
  public var resultIsEarlier: Bool {
    guard let result = latestResult, let at = result.observedAt, let progress = latestProgress else { return false }
    return progress.progress.observedAt > at && progress.progress.phase != "source-delivery"
  }
  public var resultTitle: String {
    guard let result = latestResult?.result else { return "原验收结果未提供" }
    if result.decision == "reconcile_required" { return "结果待核 · " + result.reasonTitle }
    if result.decision == "reportable_terminal" { return "原阶段未通过 · " + result.reasonTitle }
    switch result.binding?.stageId {
    case "subagent-output-available": return (resultIsEarlier ? "较早记录 · " : "") + "子任务产物可用"
    case "source-shared-delivery": return (resultIsEarlier ? "较早记录 · " : "") + "源码阶段已交付"
    default: return (resultIsEarlier ? "较早记录 · " : "") + "原阶段可交付"
    }
  }
  public var scopeTitle: String {
    switch id.binding.stageId {
    case "subagent-output-available": return "仅子产物，不等于任务完成"
    case "source-shared-delivery": return "仅源码，不代表安装或上线"
    default: return "仅原阶段，不替代其他验收"
    }
  }
  public var hasUncertainty: Bool { latestProgress?.progress.hasSourceProblem == true || latestProgress?.connected == false || latestResult?.result.decision == "reconcile_required" || latestResult?.result.decision == "reportable_terminal" || latestResult?.connected == false }
}
public enum WorkCardPresentation {
  /// An explicit PR label, not an invented task title or inferred repository.
  public static func displayTitle(_ group: WorkResultGroup) -> String {
    let targets = Set(group.progress.filter { $0.progress.valid }.map { $0.progress.repository + " #" + String($0.progress.pullRequest) })
    if targets.count == 1, let target = targets.first { return target }
    return group.id.kindTitle + " · " + String(group.id.key.prefix(12))
  }
  public static func stages(_ group: WorkResultGroup) -> [WorkStageSummary] {
    var stages: [WorkStageSummary] = [], slots: [WorkStageKey: Int] = [:], progressTargets: [WorkStageKey: [Int]] = [:]
    for entry in group.progress {
      let base = WorkStageKey(reporter: entry.reporter, observerEpoch: entry.observerEpoch, binding: entry.progress.binding)
      let key = WorkStageKey(reporter: entry.reporter, observerEpoch: entry.observerEpoch, binding: entry.progress.binding, repository: entry.progress.repository, pullRequest: entry.progress.pullRequest)
      if let index = slots[key] { stages[index].progress.append(entry) }
      else { progressTargets[base, default: []].append(stages.count); slots[key] = stages.count; stages.append(WorkStageSummary(id: key, progress: [entry])) }
    }
    for entry in group.entries {
      guard let binding = entry.result.binding else { continue }
      let key = WorkStageKey(reporter: entry.reporter, observerEpoch: entry.observerEpoch, binding: binding)
      let targets = progressTargets[key] ?? []
      if targets.count == 1 { stages[targets[0]].results.append(entry) }
      else if let index = slots[key] { stages[index].results.append(entry) }
      else { slots[key] = stages.count; stages.append(WorkStageSummary(id: key, results: [entry])) }
    }
    for entry in group.handoffs {
      guard let binding = entry.handoff.successor ?? entry.handoff.previous else { continue }
      let key = WorkStageKey(reporter: entry.reporter, observerEpoch: entry.observerEpoch, binding: binding)
      let targets = progressTargets[key] ?? []
      if targets.count == 1 { stages[targets[0]].handoffs.append(entry) }
      else if let index = slots[key] { stages[index].handoffs.append(entry) }
      else { slots[key] = stages.count; stages.append(WorkStageSummary(id: key, handoffs: [entry])) }
    }
    // Order visible summaries by original observation time only; this does not
    // promote one head/reporter into the task's authoritative current state.
    return stages.enumerated().sorted { left,right in
      left.element.lastOriginalTime == right.element.lastOriginalTime ? left.offset < right.offset : left.element.lastOriginalTime > right.element.lastOriginalTime
    }.map { $0.element }
  }
  public static func needsUserInput(_ group: WorkResultGroup) -> Bool {
    !group.inputs.isEmpty
  }
  public static func inputTitle(_ group: WorkResultGroup) -> String {
    group.inputs.isEmpty ? "未观察到关联本工作的原生输入" : "\(group.inputs.count) 项原生输入声明关联此工作"
  }
}
