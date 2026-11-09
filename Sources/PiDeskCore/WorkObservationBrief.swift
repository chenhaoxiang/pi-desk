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
    let reporters = Set(groups.flatMap { group in
      group.entries.map(\.reporter) + group.progress.map(\.reporter) + group.handoffs.map(\.reporter) + group.decisions.map(\.reporter)
    })
    reportingSourceCount = online.filter { reporters.contains($0.snapshot.identity) }.count
    lines = groups.prefix(16).map { group in
      let stages = WorkCardPresentation.stages(group)
      let details = stages.prefix(2).map { stage in
        let head = stage.id.binding.headSha.map { String($0.prefix(12)) } ?? "未提供"
        let time = stage.lastOriginalTime > 0 ? Date(timeIntervalSince1970: stage.lastOriginalTime / 1000).formatted(date: .abbreviated, time: .standard) : "未提供"
        return stage.phaseTitle + "；" + stage.waitTitle + "；原结果：" + stage.resultTitle + "；下一步：" + stage.nextTitle + "；" + stage.scopeTitle
          + "；来源 " + stage.id.reporter.nativeSessionId.suffix(8) + "；head " + head + "；原观察 " + time
      }
      return WorkCardPresentation.displayTitle(group) + " · " + WorkCardPresentation.inputTitle(group)
        + "\n原引用：" + group.id.owner + "/" + group.id.kind + "/" + group.id.key
        + (details.isEmpty ? "；阶段与原下一步未提供" : "\n  " + details.joined(separator: "\n  "))
        + (stages.count > 2 ? "\n  另有原始绑定，见工作卡；不合并整体状态。" : "")
    }
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
