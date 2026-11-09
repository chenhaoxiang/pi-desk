import Foundation

public struct SessionActivity: Codable, Equatable, Sendable {
  public var sequence: Int
  public var kind: String
  public var at: Double
  public var turnStartedAt: Double?
  public var turnEndedAt: Double?
  public var turnEndSequence: Int?
  public init(sequence: Int, kind: String, at: Double, turnStartedAt: Double? = nil, turnEndedAt: Double? = nil, turnEndSequence: Int? = nil) {
    self.sequence = sequence; self.kind = kind; self.at = at
    self.turnStartedAt = turnStartedAt; self.turnEndedAt = turnEndedAt; self.turnEndSequence = turnEndSequence
  }
  public var valid: Bool {
    func time(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 7_258_118_400_000 && value.rounded(.towardZero) == value }
    return sequence > 0 && sequence <= 9_007_199_254_740_991
      && ["agent-start", "tool-start", "tool-end", "agent-settled", "input", "child-update"].contains(kind)
      && time(at) && [turnStartedAt, turnEndedAt].allSatisfy { $0 == nil || time($0!) }
      && ((turnEndedAt == nil) == (turnEndSequence == nil))
      && (turnEndSequence == nil || (turnEndSequence! > 0 && turnEndSequence! <= sequence))
  }
}

/// A bounded display copy of an event already received from Pi. Not Codable:
/// it is neither a second source nor execution/turn-end/acceptance evidence.
public struct ObservedActivityStamp: Equatable, Sendable {
  public let source: Identity
  public let at: Double
  public let kind: String
  public let sequence: Int
  public init?(_ snapshot: Snapshot) {
    guard snapshot.identity.valid, let activity = snapshot.activity, activity.valid else { return nil }
    source = snapshot.identity; at = activity.at; kind = activity.kind; sequence = activity.sequence
  }
}

public struct SpotlightSlot: Identifiable, Sendable {
  public let identity: Identity
  public let session: SessionView?
  public var id: Identity { identity }
}

/// Display-only choices never replace runtime identity or execution evidence.
public enum SessionExperience {
  public static func elapsed(since milliseconds: Double, now: Date = Date()) -> String? {
    let elapsed = now.timeIntervalSince1970 - milliseconds / 1000
    guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 7_258_118_400_000, elapsed >= 0 else { return nil }
    if elapsed < 60 { return "刚刚" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))分钟" }
    if elapsed < 86400 { return "\(Int(elapsed / 3600))小时" }
    return "\(Int(min(elapsed / 86400, 99999)))天"
  }
  public static func timing(_ session: SessionView, now: Date = Date()) -> String {
    if Presentation.needsInput(session), let start = session.snapshot.inputs.map(\.startedAt).min(),
      let duration = elapsed(since: start, now: now) { return duration == "刚刚" ? "刚开始等待输入" : "等待输入 " + duration }
    guard let stamp = activityStamp(session) else { return "尚未观察到活动" }
    guard let duration = elapsed(since: stamp.at, now: now) else { return "活动时间待核" }
    let previousRuntime = stamp.source != session.snapshot.identity
    let lastKnown = previousRuntime || session.snapshot.activity == nil || session.connection != .connected
    if previousRuntime { return duration == "刚刚" ? "上次运行刚有活动" : "上次运行活动 " + duration + "前" }
    if lastKnown { return duration == "刚刚" ? "最后已知刚有活动" : "最后已知活动 " + duration + "前" }
    return duration == "刚刚" ? "刚有活动" : "最近活动 " + duration + "前"
  }
  public static func activityStamp(_ session: SessionView) -> ObservedActivityStamp? {
    if let current = ObservedActivityStamp(session.snapshot) { return current }
    guard let retained = session.lastObservedActivity, retained.source.sessionKey == session.snapshot.identity.sessionKey else { return nil }
    return retained
  }
  public static func activityDetail(_ session: SessionView) -> String {
    guard let stamp = activityStamp(session) else { return "本次接入尚未收到原生活动事件；状态接收时间不是活动时间。" }
    let date = Date(timeIntervalSince1970: stamp.at / 1000).formatted(date: .abbreviated, time: .standard)
    let event = ["agent-start":"回合开始", "tool-start":"工具开始", "tool-end":"工具结束", "agent-settled":"回合结束", "input":"输入等待变化", "child-update":"子任务更新"][stamp.kind] ?? "原生活动"
    let scope: String
    if stamp.source != session.snapshot.identity { scope = "上次运行记录；当前运行尚未报告活动，不代表工作停止" }
    else if session.snapshot.activity == nil { scope = "本次快照未带活动字段，保留已接收原记录" }
    else if session.connection != .connected { scope = "来源已非实时，保留最后原记录" }
    else { scope = "原生事件；不是心跳、任务进展或业务验收" }
    return event + " · " + date + " · " + scope
  }
  public static func title(_ snapshot: Snapshot) -> String {
    let name = snapshot.display.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty && name.lowercased() != "pi" { return name }
    return Presentation.project(snapshot) + " · " + snapshot.identity.nativeSessionId.suffix(6)
  }

  public static func slots(_ identities: [Identity], sessions: [String: SessionView]) -> [SpotlightSlot] {
    identities.map { identity in
      let session = sessions[identity.sessionKey]
      return SpotlightSlot(identity: identity, session: session?.snapshot.identity == identity ? session : nil)
    }
  }
  public static func spotlight(_ sessions: [SessionView], pinned: Set<String>, unread: Set<String> = [], limit: Int = 4) -> [SessionView] {
    func rank(_ session: SessionView) -> Int {
      if Presentation.needsInput(session) { return 0 }
      if Presentation.executionState(session) == .failed { return 1 }
      if unread.contains(session.snapshot.identity.sessionKey) { return 2 }
      if pinned.contains(session.snapshot.identity.sessionKey) { return 3 }
      if Presentation.isExecutionActive(session) { return 4 }
      return 5
    }
    return sessions.enumerated().filter { $0.element.connection == .connected }
      .sorted { a, b in
        let x = rank(a.element), y = rank(b.element)
        return x == y ? a.offset < b.offset : x < y
      }.prefix(max(0, min(limit, 4))).map(\.element)
  }
}
