import Foundation
import PiDeskCore

enum MissionDecisionChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let projection = try JSONDecoder().decode(MissionDecisionsProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/mission-decisions-v1.json")))
    precondition(projection.valid)
    let record = projection.missions[0]
    precondition(record.counts?.open == 1 && record.counts?.resolved == 1 && record.scopeNote.contains("仍有未决项"))
    precondition(!record.summary.contains("批准") && record.decisions[0].statusTitle == "原记录未决")
    var snapshot = base; snapshot.governance = nil; snapshot.inputs = []; snapshot.missionDecisions = projection
    let wire = WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot)
    let decoded = try Wire.decode(Data(Wire.encode(wire).dropLast()))
    precondition(decoded.snapshot?.missionDecisions == projection)
    var store = SessionStore(); precondition(store.apply(wire, connection: UUID(), now: snapshot.observedAt))
    let session = store.sessions[snapshot.identity.sessionKey]!
    precondition(!Presentation.needsInput(session), "open native decision records must not create human input requests")
    let groups = WorkResultPortfolio.groups([session])
    precondition(groups.count == 1 && groups[0].entries.isEmpty && groups[0].decisions.count == 1)
    var another = session; another.snapshot.identity.nativeSessionId = "fresh-reader"
    another.snapshot.missionDecisions?.missions[0].counts = nil
    another.snapshot.missionDecisions?.missions[0].decisions = []
    another.snapshot.missionDecisions?.missions[0].coverage = "unavailable"
    another.snapshot.missionDecisions?.missions[0].reason = "same-time-conflict"
    another.snapshot.missionDecisions?.coverage = "partial"
    precondition(another.snapshot.valid)
    let shared = WorkResultPortfolio.groups([session,another])
    precondition(shared.count == 1 && shared[0].decisions.count == 2 && shared[0].decisions[1].record.counts == nil, "independent reporters are not summed or resolved by Desk")
    var invalid = projection; invalid.missions[0].counts?.total = 1; precondition(!invalid.valid)
    invalid = projection; invalid.missions[0].decisions[0].id = "/private/id"; precondition(!invalid.valid)
    snapshot.missionDecisions = nil; precondition(snapshot.valid, "legacy snapshots remain valid")
    print("Mission decision checks passed: partial resolution, source-only status, no human approval, independent reporters, legacy and wire validation.")
  }
}
