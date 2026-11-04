import Foundation
import PiDeskCore

enum GovernanceChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let projection = try JSONDecoder().decode(GovernanceProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/work-results-v1.json")))
    precondition(projection.valid)
    precondition(projection.handoffs[0].observation.acceptedFactRefs == ["effect:a/1", "CI 41910104247 green", "已有验收引用"])
    precondition(projection.results[0].observation.statusTitle.contains("产物可用"))
    precondition(projection.results[0].observation.scopeNote.contains("不代表任务验收"))
    precondition(projection.results[1].observation.statusTitle == "待原 owner 对账")
    precondition(projection.handoffs[0].observation.nextActionTitle == "对账" && !projection.handoffs[0].observation.executable)
    var snapshot = base; snapshot.governance = projection; snapshot.inputs = []
    var store = SessionStore(); let connection = UUID()
    precondition(store.apply(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot), connection: connection, now: snapshot.observedAt))
    let original = store.sessions[snapshot.identity.sessionKey]!
    precondition(!Presentation.needsInput(original), "unknown result/next reconcile is not a human decision")
    var sameWork = original; sameWork.snapshot.identity.nativeSessionId = "another-session"
    precondition(WorkResultPortfolio.groups([original,sameWork]).count == 1, "explicit owner/kind/key groups across reporters")
    sameWork.snapshot.governance?.results[0].observation.binding?.workRef.owner = "other/owner"
    precondition(WorkResultPortfolio.groups([original,sameWork]).count == 2, "same key across owners is not same work")
    sameWork.snapshot.governance = nil
    precondition(WorkResultPortfolio.groups([sameWork]).isEmpty, "same cwd/name and Todo do not invent work binding")
    let encoded = try Wire.encode(WireRecord(kind: "snapshot", identity: snapshot.identity, snapshot: snapshot))
    let decoded = try Wire.decode(Data(encoded.dropLast()))
    precondition(decoded.snapshot?.governance == projection)
    var bad = projection; bad.results[0].observation.outcome = "unknown"; precondition(!bad.valid)
    bad = projection; bad.handoffs[0].observation.executable = true; precondition(!bad.valid)
    bad = projection; bad.results[0].observation.binding?.workRef.key = "/private/path"; precondition(!bad.valid)
    print("Governance checks passed: public binding, stage-only results, explicit grouping, no inferred human decision, old bridge, Swift/TS wire and invalid authority.")
  }
}
