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
    print(
      "AppModel draft checks passed: unavailable, duplicate/pending, disconnected preserve input; only admitted request clears."
    )
  }
}
