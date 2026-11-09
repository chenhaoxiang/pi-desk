import Foundation

/// On-demand presentation derived from the existing portfolio and snapshots.
/// No Codable/store, alternate lifecycle, business KPI, or inferred ownership.
public struct WorkObservationBrief: Sendable {
  public let observedWorkCount: Int
  public let nativeInputCount: Int
  public let inputLinkedWorkCount: Int
  public let onlineSourceCount: Int
  public let reportingSourceCount: Int
  public let oldestInputAt: Double?
  public let lines: [String]
  public init(groups: [WorkResultGroup], sessions: [SessionView]) {
    observedWorkCount = groups.count
    inputLinkedWorkCount = groups.filter(WorkCardPresentation.needsUserInput).count
    let online = sessions.filter { $0.connection == .connected }
    onlineSourceCount = online.count
    nativeInputCount = online.reduce(0) { $0 + $1.snapshot.inputs.count }
    oldestInputAt = online.flatMap { $0.snapshot.inputs }.map(\.startedAt).filter { $0.isFinite && $0 >= 0 && $0 <= 7_258_118_400_000 }.min()
    var reporters = Set<Identity>()
    for group in groups {
      group.entries.forEach { reporters.insert($0.reporter) }
      group.progress.forEach { reporters.insert($0.reporter) }
      group.handoffs.forEach { reporters.insert($0.reporter) }
      group.decisions.forEach { reporters.insert($0.reporter) }
    }
    reportingSourceCount = online.filter { reporters.contains($0.snapshot.identity) }.count
    lines = groups.prefix(16).map(Self.describe)
  }
  private static func originalTime(_ at: Double?) -> String {
    guard let at, at.isFinite, at >= 0 else { return "未提供" }
    return Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .standard)
  }
  private static func source(_ label: String, reporter: Identity, connected: Bool, at: Double?) -> String {
    let scope = connected ? "来源已接入" : "来源非实时 · 最后记录"
    return label + scope + "；来源 " + reporter.nativeSessionId.suffix(8) + "；原观察 " + originalTime(at)
  }
  private static func describe(_ stage: WorkStageSummary) -> String {
    var parts = [stage.phaseTitle, stage.waitTitle, "原结果：" + stage.resultTitle, "下一步：" + stage.nextTitle, stage.scopeTitle]
    parts.append("head " + (stage.id.binding.headSha.map { String($0.prefix(12)) } ?? "未提供"))
    if let p = stage.latestProgress { parts.append(source("进度", reporter: p.reporter, connected: p.connected, at: p.progress.observedAt)) }
    if let r = stage.latestResult { parts.append(source("结果", reporter: r.reporter, connected: r.connected, at: r.observedAt)) }
    if let h = stage.latestHandoff { parts.append(source("交接", reporter: h.reporter, connected: h.connected, at: h.observedAt)) }
    return parts.joined(separator: "；")
  }
  private static func describe(_ group: WorkResultGroup) -> String {
    let stages = WorkCardPresentation.stages(group)
    var parts = [WorkCardPresentation.displayTitle(group) + " · " + WorkCardPresentation.inputTitle(group)]
    parts.append("原引用：" + group.id.owner + "/" + group.id.kind + "/" + group.id.key)
    if stages.isEmpty { parts.append("阶段与原下一步未提供") }
    else { parts.append(contentsOf: stages.prefix(2).map { "  " + describe($0) }) }
    if stages.count > 2 { parts.append("  另有原始绑定，见工作卡；不合并整体状态。") }
    for entry in group.decisions.prefix(2) {
      parts.append("  原决策" + entry.record.summary + "；" + entry.record.scopeNote)
      parts.append("  " + source("原决策", reporter: entry.reporter, connected: entry.connected, at: entry.record.observedAt))
      parts.append("  原记录更新时间：" + originalTime(entry.record.sourceUpdatedAt))
    }
    if group.decisions.count > 2 { parts.append("  其他原决策来源未列，见工作卡；不跨来源合计。") }
    return parts.joined(separator: "\n")
  }
  public func oldestInputTitle(now: Date = Date()) -> String {
    guard let at = oldestInputAt else { return nativeInputCount > 0 ? "原生输入等待起点未提供" : "未观察到正在等待的原生输入" }
    guard let elapsed = SessionExperience.elapsed(since: at, now: now) else { return "原生输入等待起点待核" }
    return elapsed == "刚刚" ? "最长已知输入等待：刚开始" : "最长已知输入等待：" + elapsed
  }
  public func text(now: Date = Date()) -> String {
    let header = "当前已接入观察，摘要生成于 · " + now.formatted(date: .abbreviated, time: .standard)
      + "\n观察到\(observedWorkCount)个工作引用；\(nativeInputCount)项原生输入；\(reportingSourceCount)/\(onlineSourceCount)在线来源已提供明确工作引用观察（含待核）。"
      + "\n" + oldestInputTitle(now: now)
      + "\n仅当前已收到窗口，不是全天履历、交付率或业务结果；未知不作零，来源不跨运行合并。"
    return header + (lines.isEmpty ? "\n尚无可关联工作原件。" : "\n\n" + lines.joined(separator: "\n\n"))
      + (observedWorkCount > lines.count ? "\n摘要只列前16个引用，其余见工作卡；省略不代表不存在。" : "")
  }
}
