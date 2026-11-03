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
    guard let activity = session.snapshot.activity, activity.valid else { return "活动时间未提供" }
    guard let duration = elapsed(since: activity.at, now: now) else { return "活动时间待核" }
    return duration == "刚刚" ? "刚有活动" : "最近活动 " + duration + "前"
  }
  public static func title(_ snapshot: Snapshot) -> String {
    let name = snapshot.display.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty && name.lowercased() != "pi" { return name }
    return Presentation.project(snapshot) + " · " + snapshot.identity.nativeSessionId.suffix(6)
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
