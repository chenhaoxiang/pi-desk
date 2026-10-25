import Foundation
import PiDeskCore

enum StateChecks {
  static func run(_ fixture: Snapshot) throws {
    var store = SessionStore()
    let connection = UUID()
    let now = fixture.observedAt
    precondition(
      store.apply(
        WireRecord(kind: "hello", identity: fixture.identity, snapshot: fixture),
        connection: connection, now: now))
    precondition(
      !store.apply(
        WireRecord(kind: "snapshot", identity: fixture.identity, snapshot: fixture),
        connection: connection, now: now))
    let req = store.request(
      identity: fixture.identity, action: .message, target: Target(owner: "pi"),
      parameters: Parameters(text: "fixture", mode: "followUp"), now: now)!
    precondition(
      store.request(
        identity: fixture.identity, action: .message, target: Target(owner: "pi"), now: now) == nil)
    store.disconnect(connection)
    precondition(store.requests[req.requestId!]?.status == "unknown")
    var next = fixture
    next.identity.runtimeEpoch = "epoch-b"
    next.seq = 1
    next.observedAt += 1000
    precondition(
      store.apply(
        WireRecord(kind: "hello", identity: next.identity, snapshot: next), connection: UUID(),
        now: now + 1000))
    precondition(
      !store.apply(
        WireRecord(kind: "hello", identity: fixture.identity, snapshot: fixture),
        connection: UUID(), now: now + 2000))
    precondition(
      store.request(
        identity: fixture.identity, action: .abortCurrent, target: Target(owner: "pi"),
        now: now + 2000) == nil)
    precondition(store.totalUsage() == nil)
    let raw: [String: Any] = [
      "panes": [
        [
          "pane_id": "pane-a", "workspace_id": "workspace-a", "tab_id": "tab-a",
          "agent_session": [
            "source": "herdr:pi", "kind": "path", "value": "/fixture/session.jsonl",
          ],
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: raw)
    let pane = try Navigation.exactPane(snapshot: data, sessionFile: "/fixture/session.jsonl")
    precondition(pane.paneId == "pane-a")
    do {
      _ = try Navigation.exactPane(snapshot: data, sessionFile: "/fixture/missing.jsonl")
      fatalError("Wrong route admitted")
    } catch {}
    let duplicate = try JSONSerialization.data(withJSONObject: [
      "panes": (raw["panes"] as! [[String: Any]]) + (raw["panes"] as! [[String: Any]])
    ])
    do {
      _ = try Navigation.exactPane(snapshot: duplicate, sessionFile: "/fixture/session.jsonl")
      fatalError("Ambiguous route admitted")
    } catch {}
    var other = fixture
    other.identity.nativeSessionId = "another-session"
    other.observedAt += 1
    precondition(
      store.apply(
        WireRecord(kind: "hello", identity: other.identity, snapshot: other), connection: UUID(),
        now: now + 2000))
    precondition(store.sessions.count == 2)
    precondition(store.totalUsage() == nil)
    let evidenceData = Data(
      #"{"id":"ci","source":"fixture","category":"ci","status":"passed","head":"abcdef1234","observedAt":1000,"nature":"advice"}"#
        .utf8)
    var evidence = try JSONDecoder().decode(Evidence.self, from: evidenceData)
    precondition(!EvidencePolicy.isCurrentFact(evidence, head: "abcdef1234", now: 1001))
    evidence.nature = "fact"
    precondition(EvidencePolicy.isCurrentFact(evidence, head: "abcdef1234", now: 1001))
    precondition(!EvidencePolicy.isCurrentFact(evidence, head: "new-head", now: 1001))
    precondition(!EvidencePolicy.isCurrentFact(evidence, head: "abcdef1234", now: 400000))
    var inputView = store.sessions[other.identity.sessionKey]!
    precondition(Presentation.status(inputView).title == "正在运行")
    inputView.snapshot.inputs = [
      try JSONDecoder().decode(
        InputNotice.self,
        from: Data(#"{"id":"q","source":"fixture","kind":"question","startedAt":1000}"#.utf8))
    ]
    precondition(Presentation.status(inputView).title == "需要输入")
    let island = IslandGeometry.calculate(
      screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
      visible: CGRect(x: 0, y: 0, width: 1440, height: 868), safeTop: 0, cameraGap: 0)
    precondition(island.compact.width == 300 && island.expanded.width == 640)
    var interaction = IslandInteraction()
    interaction.expand()
    precondition(interaction.mayAutoCollapse)
    interaction.pinned = true
    precondition(!interaction.mayAutoCollapse)
    interaction.escape()
    precondition(interaction.expanded)
    interaction.pinned = false
    interaction.escape()
    precondition(!interaction.expanded)
    // A legacy wire-v1 session can coexist with a recorder-enabled, restricted-capability session.
    var mixed = SessionStore(), legacy = fixture, modern = fixture
    legacy.identity.nativeSessionId = "legacy-wire-no-recorder"
    legacy.usageRecorder = nil
    legacy.capabilities.owners["subagents"] = "unavailable"
    legacy.capabilities.actions = [.message, .abortCurrent]
    legacy.runs = []; legacy.schedules = []; legacy.childCoverage = "unknown"
    modern.identity.nativeSessionId = "modern-restricted-cap"
    modern.capabilities.actions = [.message]
    modern.usageRecorder = try JSONDecoder().decode(UsageRecorder.self, from: Data(#"{"version":1,"pending":0,"dropped":0,"writeFailures":0,"lastSuccessAt":1000,"reasons":[]}"#.utf8))
    let oldRecord = WireRecord(kind: "hello", identity: legacy.identity, snapshot: legacy)
    let oldBytes = try Wire.encode(oldRecord)
    precondition(!String(decoding: oldBytes, as: UTF8.self).contains("usageRecorder"))
    let decodedOld = try Wire.decode(Data(oldBytes.dropLast()))
    precondition(mixed.apply(decodedOld, connection: UUID(), now: now))
    precondition(mixed.apply(WireRecord(kind: "hello", identity: modern.identity, snapshot: modern), connection: UUID(), now: now))
    precondition(mixed.sessions.count == 2 && mixed.sessions[legacy.identity.sessionKey]?.snapshot.usageRecorder == nil)
    precondition(mixed.request(identity: modern.identity, action: .abortCurrent, target: Target(owner: "pi"), now: now) == nil)
    precondition(mixed.request(identity: legacy.identity, action: .stop, target: Target(owner: "subagents", runId: "missing-owner-run"), now: now) == nil)
    precondition(mixed.request(identity: legacy.identity, action: .message, target: Target(owner: "pi"), now: now) != nil)
    precondition(mixed.request(identity: modern.identity, action: .message, target: Target(owner: "pi"), now: now) != nil)
    precondition(mixed.request(identity: legacy.identity, action: .abortCurrent, target: Target(owner: "pi"), now: now) != nil)
    precondition(LinkPolicy.exactHTTPS("https://example.invalid/console") != nil)
    for url in [
      "file:///fixture", "javascript:alert(1)", "https://user:pass@example.invalid",
      "http://example.invalid", "https://example.invalid:8443/",
      "https://example.invalid/?token=fixture", "https://example.invalid/#fragment",
    ] { precondition(LinkPolicy.exactHTTPS(url) == nil) }
  }
}
