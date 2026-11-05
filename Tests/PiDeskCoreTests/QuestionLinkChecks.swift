import Foundation
import PiDeskCore

enum QuestionLinkChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let notice = try JSONDecoder().decode(InputNotice.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/question-link-v1.json")))
    precondition(notice.question?.valid == true && notice.question?.title == "变更 · existing-change")
    var linked = base; linked.inputs = [notice]
    let wire = WireRecord(kind: "hello", identity: linked.identity, snapshot: linked)
    let decoded = try Wire.decode(Data(Wire.encode(wire).dropLast()))
    precondition(decoded.snapshot?.inputs == [notice])
    var legacy = notice; legacy.question = nil; linked.inputs = [legacy]; precondition(linked.valid)
    var invalid = notice; invalid.question?.workRef?.key = "/private/entry"; linked.inputs = [invalid]; precondition(!linked.valid)
    invalid = notice; invalid.question?.binding = "unbound"; linked.inputs = [invalid]; precondition(!linked.valid, "unbound cannot carry a guessed work reference")
    var store = SessionStore(); let connection = UUID()
    precondition(store.apply(wire, connection: connection, now: base.observedAt))
    let session = store.sessions[base.identity.sessionKey]!
    precondition(Presentation.needsInput(session))
    var finished = linked; finished.inputs = []; finished.seq += 1
    precondition(store.apply(WireRecord(kind: "snapshot", identity: finished.identity, snapshot: finished), connection: connection, now: base.observedAt))
    precondition(!Presentation.needsInput(store.sessions[base.identity.sessionKey]!), "link metadata cannot keep a closed native input waiting")
    print("Question link checks passed: bounded optional work association, legacy wire, no guessed ownership, original input lifecycle only.")
  }
}
