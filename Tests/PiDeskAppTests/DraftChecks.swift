import Foundation
import PiDeskCore

@main enum DraftChecks {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let wire = try Wire.decode(
      Data(contentsOf: root.appendingPathComponent("Fixtures/wire-v1.json")))
    let model = AppModel()
    defer { model.stop() }
    let target = Target(owner: "pi")
    let text = "Keep this unsent draft"
    var draft = text
    if model.action(.message, target: target, parameters: Parameters(text: draft, mode: "followUp"))
    {
      draft = ""
    }
    precondition(draft == text && model.store.requests.isEmpty)
    let connection = UUID()
    precondition(
      model.store.apply(wire, connection: connection, now: Date().timeIntervalSince1970 * 1000))
    model.selected = wire.identity.sessionKey
    precondition(
      model.action(
        .message, target: target, parameters: Parameters(text: "first", mode: "followUp")))
    precondition(
      !model.action(.message, target: target, parameters: Parameters(text: text, mode: "followUp")))
    precondition(model.store.requests.count == 1)
    draft = text
    if model.action(.message, target: target, parameters: Parameters(text: draft, mode: "followUp"))
    {
      draft = ""
    }
    precondition(draft == text && model.store.requests.count == 1)
    model.store.disconnect(connection)
    precondition(
      !model.action(.message, target: target, parameters: Parameters(text: text, mode: "followUp")))
    precondition(model.store.requests.count == 1)
    var a = wire.snapshot!
    a.seq += 1
    let targetConnection = UUID()
    precondition(
      model.store.apply(
        WireRecord(kind: "hello", identity: a.identity, snapshot: a), connection: targetConnection,
        now: Date().timeIntervalSince1970 * 1000))
    var b = a
    b.identity.nativeSessionId = "visual-target-b"
    precondition(
      model.store.apply(
        WireRecord(kind: "hello", identity: b.identity, snapshot: b), connection: UUID(),
        now: Date().timeIntervalSince1970 * 1000))
    model.selected = b.identity.sessionKey
    precondition(model.action(.abortCurrent, target: target, identity: a.identity))
    precondition(
      model.store.requests.values.contains {
        $0.action == .abortCurrent && $0.identity == a.identity
      })
    var stale = a.identity
    stale.runtimeEpoch = "stale-preview-epoch"
    precondition(!model.action(.abortCurrent, target: target, identity: stale))
    model.setDraft("Draft A", for: a.identity)
    model.setDraft("Draft B", for: b.identity)
    precondition(model.drafts[a.identity] == "Draft A" && model.drafts[b.identity] == "Draft B")
    model.search = "visual-target-b"
    model.search = "合成" // Fixture names are source metadata, not an execution target.
    model.search = "NO_MATCH_123"
    precondition(model.visibleSessions.isEmpty)
    model.search = ""
    model.sessionFilter = "断连"
    precondition(model.visibleSessions.isEmpty)
    model.store.disconnect(targetConnection)
    precondition(model.visibleSessions.count == 1)
    model.hideDisconnected(a.identity)
    precondition(model.visibleSessions.isEmpty && model.store.sessions[a.identity.sessionKey] != nil)
    precondition(model.drafts[a.identity] == "Draft A")
    print(
      "AppModel draft checks passed: unavailable, duplicate/pending, disconnected preserve input; only admitted request clears."
    )
  }
}
