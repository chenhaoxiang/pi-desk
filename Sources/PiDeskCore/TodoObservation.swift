import Foundation

public struct TodoRow: Codable, Equatable, Identifiable, Sendable {
  public var id: Int
  public var subject: String
  public var activeForm: String?
  public var owner: String?
  public var status: String
  public var blockedBy: [Int]
  public var unresolvedBy: [Int]
  public var omittedDependencies: Int
  public var valid: Bool {
    id > 0 && id <= 9_007_199_254_740_991 && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && subject.utf8.count <= 160
      && (activeForm?.utf8.count ?? 0) <= 160 && (owner?.utf8.count ?? 0) <= 80 && ["pending", "in_progress", "completed"].contains(status)
      && blockedBy.count <= 16 && Set(blockedBy).count == blockedBy.count && blockedBy.allSatisfy { $0 > 0 && $0 <= 9_007_199_254_740_991 }
      && Set(unresolvedBy).count == unresolvedBy.count && Set(unresolvedBy).isSubset(of: Set(blockedBy))
      && (0...512).contains(omittedDependencies)
  }
  public var blocked: Bool { status != "completed" && (!unresolvedBy.isEmpty || omittedDependencies > 0) }
  public var statusTitle: String { status == "completed" ? "原计划已记录完成" : blocked ? "等待前置任务" : status == "in_progress" ? "原计划进行中" : "尚未开始" }
}
public struct TodoCounts: Codable, Equatable, Sendable {
  public var pending: Int
  public var inProgress: Int
  public var completed: Int
  public var total: Int
  public var valid: Bool { [pending, inProgress, completed, total].allSatisfy { (0...512).contains($0) } && pending + inProgress + completed == total }
}
public struct TodoProjection: Codable, Equatable, Sendable {
  public var version: Int
  public var source: String
  public var scope: String
  public var observerSeq: Int
  public var coverage: String
  public var observedAt: Double?
  public var sourceCall: String?
  public var counts: TodoCounts?
  public var omitted: Int
  public var tasks: [TodoRow]
  public var valid: Bool {
    guard version == 1, source == "pi.todo", scope.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
      observerSeq >= 0, observerSeq <= 9_007_199_254_740_991, ["not-observed", "observed", "partial", "unavailable"].contains(coverage),
      (0...512).contains(omitted), tasks.count <= 32, tasks.allSatisfy(\.valid), Set(tasks.map(\.id)).count == tasks.count else { return false }
    if coverage == "not-observed" || coverage == "unavailable" { return tasks.isEmpty && counts == nil && observedAt == nil && sourceCall == nil && omitted == 0 }
    guard let at = observedAt, at.isFinite, at >= 0, at <= 7_258_118_400_000, at.rounded(.towardZero) == at,
      let call = sourceCall, call.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      let counts, counts.valid, counts.total == tasks.count + omitted else { return false }
    return coverage != "observed" || omitted == 0
  }
  public var active: [TodoRow] { tasks.filter { $0.status == "in_progress" } }
  public var blocked: [TodoRow] { tasks.filter(\.blocked) }
  public var coverageTitle: String {
    switch coverage {
    case "observed": return "已观察原生任务"
    case "partial": return "部分任务已观察"
    case "unavailable": return "当前任务快照不可用"
    default: return "尚未观察到任务"
    }
  }
}
public enum WorkOverview {
  public static func currentTask(_ session: SessionView) -> String {
    guard session.connection == .connected else { return "连接不在当前状态，保留最后观测" }
    guard let todo = session.snapshot.todo, let task = todo.active.first else {
      return session.snapshot.todo?.counts?.total == 0 ? "Pi 已记录空任务清单" : "Pi 未报告进行中的任务"
    }
    return task.activeForm?.isEmpty == false ? task.activeForm! : task.subject
  }
  public static func guidance(_ session: SessionView) -> String {
    if session.connection != .connected { return "先等待原会话重新接入；不把断线当失败，不重放动作。" }
    if Presentation.needsInput(session) { return "原会话正在等待输入，打开原入口处理；问题正文未接入，不猜答案。" }
    if session.snapshot.todo?.blocked.isEmpty == false {
      return "依赖提示：先完成上面的前置任务；不等于需要你审批，owner下一步尚未接入。"
    }
    if Presentation.isExecutionActive(session) { return "原会话报告本轮仍在运行；这里不新增确认或自动催促。" }
    return "owner 尚未提供下一步／交付结果。Todo状态不等于验收，必要时打开原会话。"
  }
}
