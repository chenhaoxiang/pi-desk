import Foundation

public enum ConnectionState: String, Sendable { case connected, stale, disconnected }
public struct SessionView: Sendable {
  public var snapshot: Snapshot
  public var connectionId: UUID
  public var connection: ConnectionState
  public var receivedAt: Double
  public var firstSeenAt: Double
  public var coalesced: Int = 0
}
public struct PendingAction: Identifiable, Sendable {
  public var id: String
  public var identity: Identity
  public var action: Action
  public var target: Target
  public var status: String
  public var code: String
  public var ownerRef: String?
  public var submittedAt: Double
}
public struct SessionStore {
  public private(set) var sessions: [String: SessionView] = [:]
  public private(set) var requests: [String: PendingAction] = [:]
  private var retired: [String: [String]] = [:]
  public init() {}
  @discardableResult public mutating func apply(_ record: WireRecord, connection: UUID, now: Double)
    -> Bool
  {
    guard (try? record.validate()) != nil else { return false }
    let key = record.identity.sessionKey
    var coalesced = 0
    if ["hello", "snapshot"].contains(record.kind), let snapshot = record.snapshot {
      if let current = sessions[key] {
        if current.snapshot.identity.runtimeEpoch != record.identity.runtimeEpoch {
          guard record.kind == "hello",
            !(retired[key] ?? []).contains(record.identity.runtimeEpoch),
            snapshot.observedAt >= current.snapshot.observedAt
          else { return false }
          retired[key] = Array(
            ((retired[key] ?? []) + [current.snapshot.identity.runtimeEpoch]).suffix(8))
          makeUnknown(identity: current.snapshot.identity, code: "runtime-replaced")
        } else {
          guard snapshot.seq > current.snapshot.seq else { return false }
          coalesced = current.coalesced + max(0, snapshot.seq - current.snapshot.seq - 1)
          guard record.kind == "hello" || current.connectionId == connection else { return false }
        }
      } else {
        guard record.kind == "hello" else { return false }
        if sessions.count >= 64 {
          guard
            let old = sessions.filter({ $0.value.connection != .connected }).min(by: {
              $0.value.receivedAt < $1.value.receivedAt
            })
          else { return false }
          sessions.removeValue(forKey: old.key)
          retired.removeValue(forKey: old.key)
        }
      }
      sessions[key] = SessionView(
        snapshot: snapshot, connectionId: connection, connection: .connected, receivedAt: now,
        firstSeenAt: sessions[key]?.firstSeenAt ?? now, coalesced: coalesced)
      return true
    }
    guard let current = sessions[key], current.connectionId == connection,
      current.snapshot.identity == record.identity
    else { return false }
    if record.kind == "action-result", let id = record.requestId, let result = record.result,
      var request = requests[id], request.identity == record.identity
    {
      request.status = result.status
      request.code = result.code
      request.ownerRef = result.ownerRef
      requests[id] = request
      return true
    }
    if record.kind == "operation-update", let op = record.operation {
      // Process termination requires explicit owner evidence, never a stop receipt.
      for (id, var request) in requests
      where request.identity == record.identity && request.ownerRef == op.runId
        && request.target.owner == op.owner
      {
        request.code =
          op.terminalProof == "observed" ? "owner-terminal-observed" : "owner-" + op.state
        requests[id] = request
      }
      return true
    }
    return false
  }
  @discardableResult public mutating func updateRoute(_ route: Route, identity: Identity, connection: UUID) -> Bool {
    guard var current = sessions[identity.sessionKey], current.connectionId == connection, current.snapshot.identity == identity, current.snapshot.display.route == nil, current.connection == .connected, route.valid, route.sessionId == identity.nativeSessionId else { return false }
    current.snapshot.display.route = route
    sessions[identity.sessionKey] = current
    return true
  }
  public mutating func disconnect(_ id: UUID) {
    for (key, var value) in sessions where value.connectionId == id {
      value.connection = .disconnected
      sessions[key] = value
      makeUnknown(identity: value.snapshot.identity, code: "connection-lost")
    }
  }
  public mutating func tick(now: Double) {
    for (key, var value) in sessions
    where value.connection == .connected && now - value.receivedAt > 15000 {
      value.connection = .stale
      sessions[key] = value
    }
    for (id, var request) in requests
    where request.status == "pending" && now - request.submittedAt > 5000 {
      request.status = "unknown"
      request.code = "reply-not-observed"
      requests[id] = request
    }
  }
  private mutating func makeUnknown(identity: Identity, code: String) {
    for (id, var request) in requests
    where request.identity == identity
      && ["pending", "requested", "accepted", "queued"].contains(request.status)
    {
      request.status = "unknown"
      request.code = code
      requests[id] = request
    }
  }
  public mutating func request(
    identity: Identity, action: Action, target: Target, parameters: Parameters = Parameters(),
    now: Double
  ) -> WireRecord? {
    guard let current = sessions[identity.sessionKey], current.snapshot.identity == identity,
      current.connection == .connected, current.snapshot.capabilities.actions.contains(action)
    else { return nil }
    // One physical click -> one request. Pending/recent double-clicks never resend.
    guard
      !requests.values.contains(where: {
        $0.identity == identity && $0.action == action && $0.target == target
          && ($0.status == "pending" || now - $0.submittedAt < 500)
      })
    else { return nil }
    if requests.count >= 128 {
      let candidates = requests.values.filter { $0.status != "pending" }.sorted {
        $0.submittedAt < $1.submittedAt
      }
      guard let oldest = candidates.first else { return nil }
      requests.removeValue(forKey: oldest.id)
    }
    let id = UUID().uuidString
    requests[id] = PendingAction(
      id: id, identity: identity, action: action, target: target, status: "pending",
      code: "awaiting-owner", submittedAt: now)
    return WireRecord(
      kind: "action", identity: identity, requestId: id, issuedAt: now, action: action,
      target: target, parameters: parameters)
  }
  public mutating func failSend(_ id: String) {
    if var r = requests[id] {
      r.status = "unknown"
      r.code = "transport-unconfirmed"
      requests[id] = r
    }
  }
  public func totalUsage() -> Tokens? {
    // No native owner contract proves disjointness across independent sessions.
    // Preserve grouped reports rather than fabricate a global exact sum.
    guard sessions.count == 1, let s = sessions.values.first,
      let owner = s.snapshot.usage.first(where: {
        $0.scope == "owner-session-total" && $0.coverage == "owner-reported"
      })
    else { return nil }
    return owner.tokens
  }
}

public enum EvidencePolicy {
  public static func isCurrentFact(_ e: Evidence, head: String?, now: Double) -> Bool {
    e.nature == "fact" && e.head != nil && e.head == head && now - e.observedAt >= 0
      && now - e.observedAt <= 300_000
  }
}
public enum LinkPolicy {
  public static func exactHTTPS(_ text: String) -> URL? {
    guard let c = URLComponents(string: text), c.scheme == "https", let host = c.host,
      !host.isEmpty, c.user == nil, c.password == nil, c.fragment == nil, c.query == nil,
      c.port == nil || c.port == 443
    else { return nil }
    return c.url
  }
}
