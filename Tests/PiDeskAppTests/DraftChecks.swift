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
    precondition(model.visibleSessions.isEmpty && model.current == nil)
    model.search = ""
    model.sessionFilter = "断连"
    precondition(model.visibleSessions.isEmpty)
    model.store.disconnect(targetConnection)
    precondition(model.visibleSessions.count == 1)
    model.sessionFilter = "在线"
    precondition(model.visibleSessions.count == 1 && model.visibleSessions[0].snapshot.identity == b.identity)
    model.sessionFilter = "全部"
    precondition(model.visibleSessions.count == 2)
    model.sessionFilter = "断连"
    model.hideDisconnected(a.identity)
    precondition(model.visibleSessions.isEmpty && model.store.sessions[a.identity.sessionKey] != nil)
    precondition(model.drafts[a.identity] == "Draft A")
    let countBeforeSelect = model.store.requests.count
    model.select(a.identity)
    precondition(model.current?.snapshot.identity == a.identity && model.sessionFilter == "全部")
    precondition(model.store.requests.count == countBeforeSelect)
    precondition(model.requiresDraftConfirmation, "normal app quit must protect unsent drafts")
    model.setDraft("", for: a.identity); model.setDraft("   ", for: b.identity)
    precondition(!model.requiresDraftConfirmation, "empty/whitespace input does not invent an exit blocker")
    let beforePalette = model.store.requests.count
    let entries = model.commandEntries()
    precondition(entries.contains { $0.action == "drafts" } && entries.contains { $0.title.contains("接入健康") })
    if let entry = entries.first(where: { $0.action == "select" && $0.identity == b.identity }) {
      model.modal = .commands; model.performCommand(entry)
      precondition(model.modal == nil && model.current?.snapshot.identity == b.identity && model.store.requests.count == beforePalette, "palette selection is local navigation, not an owner query")
    } else { fatalError("missing palette session") }
    model.performCommand(DeskCommandEntry(id: "retired", title: "same name", action: "select", identity: stale))
    precondition(model.store.requests.count == beforePalette && model.navigationNotice?.contains("已更新") == true)
    for index in 0..<64 {
      model.setDraft("protected \(index)", for: Identity(localHostId: "fixture", nativeSessionId: "draft-cap-\(index)", runtimeEpoch: "epoch"))
    }
    let fullDrafts = model.drafts
    model.setDraft("must not evict", for: Identity(localHostId: "fixture", nativeSessionId: "draft-overflow", runtimeEpoch: "epoch"))
    precondition(model.drafts == fullDrafts && model.unsentDraftIdentities.count == 64, "capacity must never silently evict another unsent draft")
    let firstDraft = model.unsentDraftIdentities[0]
    model.setDraft(String(repeating: "x", count: 16385), for: firstDraft)
    precondition(model.drafts == fullDrafts, "oversized paste keeps the prior draft")
    print(
      "AppModel draft checks passed: unavailable, duplicate/pending, disconnected preserve input; only admitted request clears."
    )
  }
}
