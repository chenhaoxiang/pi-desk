import Foundation
import PiDeskCore

enum IntercomRelationsChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let projection = try JSONDecoder().decode(IntercomRelationsProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/intercom-relations-v1.json")))
    precondition(projection.valid)
    precondition(projection.records[0].relations?.supersededBy == "new-question")
    precondition(projection.records[1].replyTitle == "原回复等待仍在")
    var snapshot = base; snapshot.inputs = []; snapshot.governance = nil; snapshot.missionDecisions = nil; snapshot.intercomRelations = projection
    let wire = WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot)
    let decoded = try Wire.decode(Data(Wire.encode(wire).dropLast()))
    precondition(decoded.snapshot?.intercomRelations == projection)
    var store = SessionStore(); precondition(store.apply(wire, connection: UUID(), now: snapshot.observedAt))
    let session = store.sessions[snapshot.identity.sessionKey]!
    precondition(!Presentation.needsInput(session))
    precondition(WorkResultPortfolio.groups([session]).isEmpty, "transport messages are not work items")
    var invalid = projection; invalid.records[0].relations?.replyCorrelation = "matched"; precondition(!invalid.valid)
    invalid = projection; invalid.records[0].relations?.senderSessionId = "/private/id"; precondition(!invalid.valid)
    invalid = projection; invalid.records[0].relations?.supersededBy = "old-question"; precondition(!invalid.valid)
    var late = projection.records[0]; late.messageId = "late-answer"; late.relations?.supersededBy = nil; late.relations?.lateReplyTo = "old-question"; late.relations?.replyCorrelation = "late"
    precondition(late.valid && late.relations!.summary.contains("未匹配"))
    var legacy = base; legacy.intercomRelations = nil; precondition(legacy.valid)
    print("Intercom relation checks passed: optional wire, transport-only status, no work/input/approval inference, original IDs and invalid metadata.")
  }
}
