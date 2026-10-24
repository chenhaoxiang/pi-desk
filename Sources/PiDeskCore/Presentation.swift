import CoreGraphics
import Foundation

public enum StatusTone: String, Sendable { case green, amber, blue, red, muted }
public struct HumanStatus: Equatable, Sendable {
  public let title: String
  public let symbol: String
  public let tone: StatusTone
}
public enum Presentation {
  public static func status(_ session: SessionView) -> HumanStatus {
    if session.connection == .disconnected {
      return HumanStatus(title: "已断开", symbol: "wifi.slash", tone: .muted)
    }
    if session.connection == .stale {
      return HumanStatus(title: "状态较旧", symbol: "clock.badge.exclamationmark", tone: .amber)
    }
    if !session.snapshot.inputs.isEmpty {
      return HumanStatus(title: "需要输入", symbol: "questionmark.circle.fill", tone: .amber)
    }
    switch session.snapshot.execution {
    case .starting: return HumanStatus(title: "正在启动", symbol: "circle.dotted", tone: .blue)
    case .running: return HumanStatus(title: "正在运行", symbol: "play.circle.fill", tone: .green)
    case .retrying:
      return HumanStatus(title: "自动重试中", symbol: "arrow.clockwise.circle", tone: .blue)
    case .compacting:
      return HumanStatus(title: "正在整理上下文", symbol: "rectangle.compress.vertical", tone: .blue)
    case .waitingChildren:
      return HumanStatus(
        title: "等待子任务", symbol: "point.3.connected.trianglepath.dotted", tone: .blue)
    case .settled: return HumanStatus(title: "本轮已结束", symbol: "checkmark.circle", tone: .muted)
    case .failed:
      return HumanStatus(title: "本轮出现异常", symbol: "exclamationmark.circle.fill", tone: .red)
    case .aborted: return HumanStatus(title: "本轮已中止", symbol: "stop.circle", tone: .muted)
    case .unknown: return HumanStatus(title: "状态未知", symbol: "questionmark.circle", tone: .muted)
    }
  }
  public static func priority(_ s: SessionView) -> Int {
    if s.connection == .connected && !s.snapshot.inputs.isEmpty { return 0 }
    if s.snapshot.execution == .failed { return 1 }
    if s.connection != .connected { return 3 }
    if [.running, .retrying, .compacting, .waitingChildren, .starting].contains(
      s.snapshot.execution)
    {
      return 2
    }
    return 4
  }
  public static func project(_ s: Snapshot) -> String {
    guard let cwd = s.display.cwd else { return "项目未提供" }
    let part = URL(fileURLWithPath: cwd).lastPathComponent
    return part.isEmpty ? "项目未提供" : part
  }
  public static func shortModel(_ s: Snapshot) -> String {
    s.display.model?.split(separator: "/").last.map(String.init) ?? "模型未知"
  }
  public static func effort(_ raw: String?) -> String {
    switch raw {
    case "off": return "关闭"
    case "minimal": return "最少"
    case "low": return "低"
    case "medium": return "中"
    case "high": return "高"
    case "xhigh": return "更高"
    case "max": return "最高"
    default: return "未知"
    }
  }
  public static func coverage(_ raw: String) -> String {
    switch raw {
    case "partial": return "部分覆盖"
    case "owner-reported": return "原系统报告"
    case "complete": return "完整覆盖"
    default: return "覆盖未知"
    }
  }
  public static func connection(_ raw: ConnectionState) -> String {
    switch raw {
    case .connected: return "已连接"
    case .stale: return "状态较旧"
    case .disconnected: return "已断开"
    }
  }
  public static func tool(_ name: String) -> String {
    switch name {
    case "bash": return "执行命令"
    case "read": return "读取文件"
    case "write": return "写入文件"
    case "edit": return "编辑文件"
    case "subagent": return "运行子任务"
    case "web_search": return "查询资料"
    case "fetch_content": return "读取资料"
    default: return "工具：" + name
    }
  }
  public static func activity(_ s: SessionView) -> String {
    if s.connection != .connected { return "保留最后一次状态，不代表工作停止" }
    if !s.snapshot.inputs.isEmpty { return "原会话正在等待输入，请回到原入口处理" }
    if !s.snapshot.tools.isEmpty {
      return s.snapshot.tools.prefix(3).map(tool).joined(separator: " · ")
    }
    switch s.snapshot.execution {
    case .settled: return "本轮对话已结束，目标验收状态未核"
    case .waitingChildren: return "原系统正在等待子任务，自动化仍独立推进"
    case .failed: return "原系统报告本轮异常，请查看原会话"
    case .unknown: return "暂未获得准确执行状态"
    case .aborted: return "本轮已中止，不代表所有后续工作已取消"
    default: return "按原规则推进，无需守着界面"
    }
  }
  public static func runState(_ raw: String) -> String {
    switch raw {
    case "running": return "运行中"
    case "queued": return "已确认排队"
    case "pending": return "待处理"
    case "paused": return "已暂停"
    case "stopped": return "已停止"
    case "stopping": return "正在停止"
    case "complete", "completed": return "运行已结束"
    case "failed": return "运行失败"
    case "partial": return "结果不完整"
    case "rejected": return "已拒绝"
    case "passed": return "报告通过"
    case "enabled", "scheduled": return "等待下次触发"
    case "disabled": return "已停用"
    default: return "未知"
    }
  }
  public static func action(_ action: Action) -> String {
    switch action {
    case .message: return "发送要求"
    case .abortCurrent: return "中止当前回合"
    case .steer: return "纠偏子任务"
    case .stop: return "请求停止子任务"
    case .resume: return "恢复原子任务"
    case .pauseSchedule: return "暂停未来触发"
    case .resumeSchedule: return "恢复计划"
    case .runSchedule: return "请求触发"
    case .deleteSchedule: return "删除计划"
    }
  }
  public static func receipt(_ raw: String) -> String {
    switch raw {
    case "pending": return "等待原系统回执"
    case "requested": return "已发出请求"
    case "accepted": return "原系统已受理"
    case "queued": return "原系统已确认排队"
    case "rejected": return "请求被拒绝"
    default: return "结果未知"
    }
  }
  public static func count(_ v: Double?) -> String {
    guard let v = v else { return "未知" }
    if v >= 1_000_000 { return String(format: "%.1fm", v / 1_000_000) }
    if v >= 1000 { return String(format: "%.1fk", v / 1000) }
    return String(format: "%.0f", v)
  }
  public static func usage(_ s: Snapshot) -> (tokens: Tokens, scope: String, coverage: String) {
    if let owner = s.usage.first(where: {
      $0.scope == "owner-session-total" || $0.scope == "native-session-total"
    }) {
      return (owner.tokens, "当前会话（原系统）", coverage(owner.coverage))
    }
    let reports = s.usage.filter { $0.scope == "attachment-window" }
    guard let first = reports.first, reports.allSatisfy({ $0.windowId == first.windowId }) else {
      return (Tokens(), "本次接入", "覆盖未知")
    }
    func sum(_ key: KeyPath<Tokens, Double?>) -> Double? {
      let values = reports.map { $0.tokens[keyPath: key] }
      guard values.allSatisfy({ $0 != nil }) else { return nil }
      return values.compactMap { $0 }.reduce(0, +)
    }
    return (
      Tokens(
        input: sum(\.input), output: sum(\.output), cacheRead: sum(\.cacheRead),
        cacheWrite: sum(\.cacheWrite)), "本次接入", "部分覆盖"
    )
  }
}

public struct IslandGeometry: Sendable {
  public let compact: CGRect
  public let expanded: CGRect
  public let cameraGap: Double
  public let topInset: Double
  public static func calculate(screen: CGRect, visible: CGRect, safeTop: Double, cameraGap: Double)
    -> IslandGeometry
  {
    let notched = safeTop > 0 && cameraGap > 0
    let screenWidth = screen.size.width
    let screenMidX = screen.origin.x + screen.size.width / 2
    let gap = notched ? min(max(cameraGap, 0), screenWidth - 200) : 0
    let width = min(screenWidth - 32, notched ? max(300, gap + 268) : 300)
    let height = notched ? max(38, safeTop + 8) : 38
    let top =
      notched ? screen.origin.y + screen.size.height : visible.origin.y + visible.size.height - 6
    let expandedWidth = min(640, screenWidth - 32)
    let expandedHeight = min(660, visible.size.height - 32)
    return IslandGeometry(
      compact: CGRect(x: screenMidX - width / 2, y: top - height, width: width, height: height),
      expanded: CGRect(
        x: screenMidX - expandedWidth / 2, y: top - expandedHeight, width: expandedWidth,
        height: expandedHeight), cameraGap: gap, topInset: notched ? safeTop : 0)
  }
}
public struct IslandInteraction: Equatable, Sendable {
  public var expanded = false
  public var pinned = false
  public var editing = false
  public init() {}
  public var mayAutoCollapse: Bool { expanded && !pinned && !editing }
  public mutating func expand() { expanded = true }
  public mutating func collapse() {
    expanded = false
    pinned = false
    editing = false
  }
  public mutating func escape() {
    if editing { editing = false } else if !pinned { expanded = false }
  }
}
