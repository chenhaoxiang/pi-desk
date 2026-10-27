import CoreGraphics
import Foundation

public enum StatusTone: String, Sendable { case green, amber, blue, red, muted }
public struct HumanStatus: Equatable, Sendable {
  public let title: String
  public let symbol: String
  public let tone: StatusTone
}
public enum Presentation {
  public static func connectionStatus(_ session: SessionView) -> HumanStatus {
    switch session.connection {
    case .connected: return HumanStatus(title: "Pi已接入", symbol: "link", tone: .green)
    case .stale: return HumanStatus(title: "状态较旧", symbol: "clock.badge.exclamationmark", tone: .amber)
    case .disconnected: return HumanStatus(title: "已断开", symbol: "wifi.slash", tone: .muted)
    }
  }
  public static func hasExecutionEvidence(_ session: SessionView) -> Bool {
    guard let proof = session.snapshot.executionObservation, proof.valid else { return false }
    let age = session.snapshot.observedAt - proof.observedAt
    return age >= 0 && age <= 15_000
  }
  public static func needsInput(_ session: SessionView) -> Bool {
    session.connection == .connected && !session.snapshot.inputs.isEmpty
  }
  public static func executionState(_ session: SessionView) -> Execution {
    guard session.connection == .connected else { return .unknown }
    let s = session.snapshot
    if hasExecutionEvidence(session), let proof = s.executionObservation {
      if !proof.idle { return [.retrying, .compacting].contains(s.execution) ? s.execution : .running }
      if [.failed, .aborted].contains(s.execution) { return s.execution }
      if s.runs.contains(where: { $0.terminalProof != "observed" && ["running", "queued", "stopping"].contains($0.state) }) { return .waitingChildren }
      return .settled
    }
    // Preserve legacy outcome records, but neither an old running enum nor a
    // new heartbeat proves that AI/tools are still executing now. SHA is not a gate.
    return [.settled, .failed, .aborted].contains(s.execution) ? s.execution : .unknown
  }
  public static func isPotentiallyActive(_ session: SessionView) -> Bool {
    session.connection == .connected && !needsInput(session)
      && [.starting, .running, .retrying, .compacting, .waitingChildren].contains(session.snapshot.execution)
  }
  public static func needsExecutionReview(_ session: SessionView) -> Bool {
    guard session.connection == .connected, !needsInput(session) else { return false }
    return (!hasExecutionEvidence(session) && isPotentiallyActive(session))
      || (hasExecutionEvidence(session) && executionState(session) == .unknown)
  }
  public static func isExecutionActive(_ session: SessionView) -> Bool {
    session.connection == .connected && !needsInput(session) && hasExecutionEvidence(session)
      && [.starting, .running, .retrying, .compacting, .waitingChildren].contains(executionState(session))
  }
  public static func executionStatus(_ session: SessionView) -> HumanStatus {
    guard session.connection == .connected else {
      return HumanStatus(title: "执行状态待核", symbol: "questionmark.circle", tone: .muted)
    }
    if needsInput(session) {
      return HumanStatus(title: "等待输入", symbol: "questionmark.circle.fill", tone: .amber)
    }
    let state = executionState(session)
    if session.snapshot.pending == true && [.settled, .unknown].contains(state) {
      return HumanStatus(title: "等待后续推进", symbol: "clock", tone: .blue)
    }
    switch state {
    case .starting: return HumanStatus(title: "正在启动", symbol: "circle.dotted", tone: .blue)
    case .running: return HumanStatus(title: "本轮运行", symbol: "play.circle.fill", tone: .green)
    case .retrying: return HumanStatus(title: "自动重试中", symbol: "arrow.clockwise.circle", tone: .blue)
    case .compacting: return HumanStatus(title: "正在整理上下文", symbol: "rectangle.compress.vertical", tone: .blue)
    case .waitingChildren: return HumanStatus(title: "等待子任务", symbol: "point.3.connected.trianglepath.dotted", tone: .blue)
    case .settled: return HumanStatus(title: hasExecutionEvidence(session) ? "本轮已结束" : "上次已结束", symbol: "checkmark.circle", tone: .muted)
    case .failed: return HumanStatus(title: hasExecutionEvidence(session) ? "本轮出现异常" : "上次出现异常", symbol: "exclamationmark.circle.fill", tone: .red)
    case .aborted: return HumanStatus(title: hasExecutionEvidence(session) ? "本轮已中止" : "上次已中止", symbol: "stop.circle", tone: .muted)
    case .unknown: return HumanStatus(title: "状态待核", symbol: "questionmark.circle", tone: .muted)
    }
  }
  // Existing callers use status for the execution layer. Connection is shown separately.
  public static func status(_ session: SessionView) -> HumanStatus { executionStatus(session) }
  public static func executionCoverage(_ session: SessionView) -> String {
    if hasExecutionEvidence(session) { return "原Pi标量状态已对账（独立于连接心跳）" }
    return session.snapshot.executionObservation == nil ? "旧桥接未提供执行状态对账；在线不代表AI正在执行，等待自然加载新版" : "连接仍在线，但执行状态观测已较旧；未用心跳冒充新证据"
  }
  public static func priority(_ s: SessionView) -> Int {
    if needsInput(s) { return 0 }
    if executionState(s) == .failed { return 1 }
    if s.connection != .connected { return 3 }
    if s.snapshot.pending == true || isExecutionActive(s) { return 2 }
    return 4
  }
  public static func createdShort(_ s: Snapshot, now: Date = Date()) -> String {
    guard let value = s.display.createdAt else { return "创建：未知" }
    let date = Date(timeIntervalSince1970: value / 1000)
    let calendar = Calendar.current
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "今天 HH:mm" : "M/d HH:mm"
    return "创建：" + formatter.string(from: date)
  }
  public static func createdAbsolute(_ s: Snapshot, now: Date = Date()) -> String {
    guard let value = s.display.createdAt else { return "创建时间未知（未从session header取得）" }
    let date = Date(timeIntervalSince1970: value / 1000)
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    let elapsed = now.timeIntervalSince(date)
    let relative: String
    if elapsed < 0 { relative = "未来时间，待核对时钟" }
    else if elapsed < 60 { relative = "刚刚" }
    else if elapsed < 3600 { relative = "\(Int(elapsed / 60))分钟前" }
    else if elapsed < 86400 { relative = "\(Int(elapsed / 3600))小时前" }
    else { relative = "\(Int(min(elapsed / 86400, Double(Int.max - 1))))天前" }
    let source = s.display.createdAtSource == "session-header" ? "session header" : "未知"
    return "创建时间：" + formatter.string(from: date) + "（" + relative + "，来源：" + source + "）"
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
    case .connected: return "Pi已接入"
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
    if needsInput(s) { return "原会话正在等待输入，请回到原入口处理" }
    if executionState(s) == .unknown {
      return hasExecutionEvidence(s) ? "暂未获得准确执行状态" : "执行状态待核（原始状态：\(s.snapshot.execution.rawValue)）；Pi仍已接入"
    }
    if hasExecutionEvidence(s), s.snapshot.executionObservation?.idle == false, !s.snapshot.tools.isEmpty {
      return s.snapshot.tools.prefix(3).map(tool).joined(separator: " · ")
    }
    if s.snapshot.pending == true { return "原会话仍有待处理消息，尚不代表AI正在执行" }
    switch executionState(s) {
    case .settled: return hasExecutionEvidence(s) ? "本轮对话已结束，Pi仍已接入；目标验收状态未核" : "上次观测本轮已结束；Pi仍已接入，当前执行状态待核"
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
    case "terminal": return "进程已结束（结果另核）"
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
