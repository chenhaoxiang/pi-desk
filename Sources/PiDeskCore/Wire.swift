import Foundation

public enum WireError: Error, Equatable {
  case invalidRecord, oversized, invalidUTF8, incompatibleVersion
}
public enum Execution: String, Codable, Sendable {
  case starting, running, retrying, compacting
  case waitingChildren = "waiting-children"
  case settled, failed, aborted, unknown
}
public enum Action: String, Codable, CaseIterable, Sendable {
  case message = "session.message"
  case abortCurrent = "session.abort-current"
  case steer = "run.steer"
  case stop = "run.stop"
  case resume = "run.resume"
  case pauseSchedule = "schedule.pause"
  case resumeSchedule = "schedule.resume"
  case runSchedule = "schedule.run"
  case deleteSchedule = "schedule.delete"
}
public struct Identity: Codable, Hashable, Sendable {
  public var localHostId: String
  public var nativeSessionId: String
  public var runtimeEpoch: String
  public var sessionKey: String { localHostId + ":" + nativeSessionId }
  public init(localHostId: String, nativeSessionId: String, runtimeEpoch: String) {
    self.localHostId = localHostId
    self.nativeSessionId = nativeSessionId
    self.runtimeEpoch = runtimeEpoch
  }
  public var valid: Bool {
    [localHostId, nativeSessionId, runtimeEpoch].allSatisfy {
      !$0.isEmpty && $0.utf8.count <= 128
        && $0.unicodeScalars.allSatisfy {
          CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
          ).contains($0)
        }
    }
  }
}
public struct Capabilities: Codable, Equatable, Sendable {
  public var actions: [Action]
  public var queries: [String]
  public var owners: [String: String]
}
public struct Display: Codable, Equatable, Sendable {
  public var name: String
  public var cwd: String?
  public var branch: String?
  public var worktree: String?
  public var model: String?
  public var effort: String?
  public var mode: String
  public var route: Route?
  public var createdAt: Double? = nil
  public var createdAtSource: String? = nil
}
public struct Route: Codable, Equatable, Sendable {
  public var kind: String
  public var sessionId: String
  public var sessionFile: String?
  public var cwd: String?
  public var ttyPath: String? = nil
  public var terminalApp: String? = nil
  public var terminalSessionId: String? = nil
  public var tmuxPane: String? = nil
  public var weztermPane: String? = nil
  public var cmuxWorkspace: String? = nil
  public var surface: String? = nil
  public init(kind: String, sessionId: String, sessionFile: String? = nil, cwd: String? = nil, ttyPath: String? = nil, terminalApp: String? = nil) {
    self.kind = kind; self.sessionId = sessionId; self.sessionFile = sessionFile; self.cwd = cwd; self.ttyPath = ttyPath; self.terminalApp = terminalApp
  }
  public var valid: Bool {
    func safe(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil }
    let values = [sessionFile, cwd, ttyPath, terminalApp, terminalSessionId, tmuxPane, weztermPane, cmuxWorkspace, surface]
    return safe(kind) && safe(sessionId) && values.allSatisfy { $0 == nil || $0!.utf8.count <= 512 }
      && (ttyPath == nil || ttyPath!.range(of: "^/dev/(ttys[A-Za-z0-9]+|pts/[0-9]+)$", options: .regularExpression) != nil)
  }
}
public struct Tokens: Codable, Equatable, Sendable {
  public var input: Double?
  public var output: Double?
  public var cacheRead: Double?
  public var cacheWrite: Double?
  public var total: Double? {
    guard let a = input, let b = output, let c = cacheRead, let d = cacheWrite else { return nil }
    return a + b + c + d
  }
  public init(
    input: Double? = nil, output: Double? = nil, cacheRead: Double? = nil, cacheWrite: Double? = nil
  ) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }
  public var valid: Bool {
    [input, output, cacheRead, cacheWrite].allSatisfy {
      $0 == nil || ($0!.isFinite && $0! >= 0 && $0! <= 9_007_199_254_740_991)
    }
  }
}
public struct UsageReport: Codable, Equatable, Sendable {
  public var source: String
  public var scope: String
  public var windowId: String
  public var model: String?
  public var observedAt: Double?
  public var startedAt: Double?
  public var coverage: String
  public var tokens: Tokens
  public var cost: Double?
  public var unresolvedChildren: Int?
  public var includedRunIds: [String]
  public var accountingGroup: String?
  public var reasons: [String]
}
public struct Run: Codable, Equatable, Identifiable, Sendable {
  public var key: String
  public var id: String { key }
  public var runId: String?
  public var parentRunId: String?
  public var index: Int?
  public var owner: String
  public var state: String
  public var agent: String?
  public var model: String?
  public var effort: String?
  public var terminalProof: String?
  public var actions: [Action]
}
public struct Schedule: Codable, Equatable, Identifiable, Sendable {
  public var owner: String
  public var scheduleId: String
  public var name: String
  public var state: String
  public var actions: [Action]
  public var id: String { owner + ":" + scheduleId }
}
public struct InputNotice: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var source: String
  public var kind: String
  public var startedAt: Double
}
public struct ExecutionObservation: Codable, Equatable, Sendable {
  public var version: Int
  public var observedAt: Double
  public var source: String
  public var idle: Bool
  public var valid: Bool {
    version == 1 && observedAt.isFinite && observedAt >= 0
      && ["ctx.isIdle", "lifecycle"].contains(source)
  }
}
public struct Evidence: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var source: String
  public var category: String
  public var status: String
  public var head: String?
  public var observedAt: Double
  public var nature: String
}
public struct UsageRecorder: Codable, Equatable, Sendable {
  public var version: Int
  public var pending: Int
  public var dropped: Int
  public var writeFailures: Int
  public var lastSuccessAt: Double?
  public var reasons: [String]
}
public struct Snapshot: Codable, Equatable, Sendable {
  public var omitted: [String: Int]?
  public var identity: Identity
  public var seq: Int
  public var observedAt: Double
  public var capabilities: Capabilities
  public var display: Display
  public var execution: Execution
  public var pending: Bool?
  public var executionObservation: ExecutionObservation?
  public var childCoverage: String
  public var tools: [String]
  public var runs: [Run]
  public var schedules: [Schedule]
  public var usage: [UsageReport]
  public var inputs: [InputNotice]
  public var evidence: [Evidence]
  public var dropped: Int
  public var contextTokens: Double?
  public var usageRecorder: UsageRecorder?
  public var valid: Bool {
    identity.valid && seq >= 0 && observedAt.isFinite && observedAt > 0 && dropped >= 0
      && display.name.utf8.count <= 512 && (display.cwd?.utf8.count ?? 0) <= 512
      && (display.createdAt == nil || (display.createdAt!.isFinite && display.createdAt! >= 0 && display.createdAt! <= 7_258_118_400_000 && display.createdAt!.rounded(.towardZero) == display.createdAt!))
      && (display.createdAtSource == nil || ["session-header", "unknown"].contains(display.createdAtSource!))
      && (executionObservation == nil || executionObservation!.valid)
      && (display.route == nil || display.route!.valid)
      && tools.count <= 32 && runs.count <= 64 && schedules.count <= 64 && inputs.count <= 32
      && usage.count <= 8 && evidence.count <= 32 && tools.allSatisfy { $0.utf8.count <= 128 }
      && usage.allSatisfy { $0.tokens.valid && $0.includedRunIds.count <= 128 }
      && Set(runs.map(\.key)).count == runs.count
      && Set(schedules.map(\.id)).count == schedules.count
      && Set(inputs.map(\.id)).count == inputs.count
  }
}
public struct Target: Codable, Equatable, Sendable {
  public var owner: String
  public var runId: String?
  public var index: Int?
  public var scheduleId: String?
  public init(owner: String, runId: String? = nil, index: Int? = nil, scheduleId: String? = nil) {
    self.owner = owner
    self.runId = runId
    self.index = index
    self.scheduleId = scheduleId
  }
}
public struct Parameters: Codable, Equatable, Sendable {
  public var text: String?
  public var mode: String?
  public var eventName: String?
  public var eventId: String?
  public init(
    text: String? = nil, mode: String? = nil, eventName: String? = nil, eventId: String? = nil
  ) {
    self.text = text
    self.mode = mode
    self.eventName = eventName
    self.eventId = eventId
  }
}
public struct ActionResult: Codable, Equatable, Sendable {
  public var status: String
  public var code: String
  public var ownerRef: String?
}
public struct Operation: Codable, Equatable, Sendable {
  public var owner: String
  public var runId: String
  public var state: String
  public var terminalProof: String?
}
public struct WireRecord: Codable, Sendable {
  public var version: Int = 1
  public var kind: String
  public var identity: Identity
  public var snapshot: Snapshot?
  public var requestId: String?
  public var issuedAt: Double?
  public var action: Action?
  public var target: Target?
  public var parameters: Parameters?
  public var query: String?
  public var result: ActionResult?
  public var operation: Operation?
  public init(
    kind: String, identity: Identity, snapshot: Snapshot? = nil, requestId: String? = nil,
    issuedAt: Double? = nil, action: Action? = nil, target: Target? = nil,
    parameters: Parameters? = nil, query: String? = nil
  ) {
    self.kind = kind
    self.identity = identity
    self.snapshot = snapshot
    self.requestId = requestId
    self.issuedAt = issuedAt
    self.action = action
    self.target = target
    self.parameters = parameters
    self.query = query
  }
  public func validate() throws {
    guard version == 1 else { throw WireError.incompatibleVersion }
    guard identity.valid else { throw WireError.invalidRecord }
    switch kind {
    case "hello", "snapshot":
      guard let s = snapshot, s.identity == identity, s.valid else { throw WireError.invalidRecord }
    case "action":
      guard let id = requestId, !id.isEmpty, id.utf8.count <= 128, let date = issuedAt,
        date.isFinite, action != nil, target != nil, (parameters?.text?.utf8.count ?? 0) <= 16384
      else { throw WireError.invalidRecord }
    case "query":
      guard requestId != nil,
        ["refresh", "usage.refresh", "schedules.refresh", "operation.status"].contains(query ?? "")
      else { throw WireError.invalidRecord }
    case "action-result":
      guard requestId != nil, let r = result,
        ["rejected", "accepted", "queued", "requested", "unknown"].contains(r.status),
        r.code.utf8.count <= 128
      else { throw WireError.invalidRecord }
    case "operation-update": guard operation != nil else { throw WireError.invalidRecord }
    default: throw WireError.invalidRecord
    }
  }
}
public enum Wire {
  public static let maximumFrame = 65_536
  public static func decode(_ data: Data) throws -> WireRecord {
    guard data.count <= maximumFrame else { throw WireError.oversized }
    guard String(data: data, encoding: .utf8) != nil else { throw WireError.invalidUTF8 }
    let value = try JSONDecoder().decode(WireRecord.self, from: data)
    try value.validate()
    return value
  }
  public static func encode(_ record: WireRecord) throws -> Data {
    try record.validate()
    var data = try JSONEncoder().encode(record)
    guard data.count <= maximumFrame else { throw WireError.oversized }
    data.append(10)
    return data
  }
}
