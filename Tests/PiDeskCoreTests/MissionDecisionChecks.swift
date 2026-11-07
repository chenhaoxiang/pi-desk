import Foundation
import PiDeskCore

enum MissionDecisionChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let projection = try JSONDecoder().decode(MissionDecisionsProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/mission-decisions-v1.json")))
    precondition(projection.valid)
    let record = projection.missions[0]
    precondition(record.counts?.open == 1 && record.counts?.resolved == 1 && record.scopeNote.contains("仍有未决项"))
    let typed = try JSONDecoder().decode(MissionDecisionsProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/mission-decisions-typed-v1.json")))
    precondition(typed.valid)
    let typedRecord = typed.missions[0]
    let typedD1 = typedRecord.decisions.first { $0.id == "d1" }!
    let typedD2 = typedRecord.decisions.first { $0.id == "d2" }!
    precondition(typedD1.statusTitle == "已被替换" && typedD1.closeReason == "superseded" && typedD1.supersededBy == "d3")
    precondition(typedD2.statusTitle == "原记录未决" && typedD2.intentTitle?.contains("仍需看旧项关闭") == true)
    let legacy = typedRecord.decisions.first { $0.id == "legacy" }!
    precondition(legacy.statusTitle.contains("关闭原因未提供") && legacy.closeReason == nil)
    var invalidTyped = typed
    invalidTyped.missions[0].decisions[2].supersededBy = "missing"
    precondition(!invalidTyped.valid)
    invalidTyped = typed
    invalidTyped.missions[0].decisions[0].supersedes = "missing"
    precondition(!invalidTyped.valid)
    precondition(typedRecord.decisions.first { $0.id == "answered" }?.statusTitle == "收到答复记录")
    precondition(typedRecord.decisions.first { $0.id == "withdrawn" }?.statusTitle == "原负责人撤回")
    invalidTyped = typed; invalidTyped.missions[0].decisions[2].closeReason = "approved"; precondition(!invalidTyped.valid)
    invalidTyped = typed; invalidTyped.missions[0].decisions[0].closeReason = "answered"; precondition(!invalidTyped.valid)
    invalidTyped = typed; invalidTyped.missions[0].decisions[2].resolvedAt = nil; precondition(!invalidTyped.valid)
    invalidTyped = typed; invalidTyped.missions[0].decisions[2].supersedes = "d2"; precondition(!invalidTyped.valid)
    invalidTyped = typed; invalidTyped.missions[0].decisions[0].supersedes = "d2"; precondition(!invalidTyped.valid)
    // A chosen replacement can later be answered/withdrawn/replaced itself.
    var later = typed
    later.missions[0].decisions[1].status = "resolved"; later.missions[0].decisions[1].closeReason = "withdrawn"; later.missions[0].decisions[1].resolvedAt = typedRecord.sourceUpdatedAt
    later.missions[0].counts?.open = 1; later.missions[0].counts?.resolved = 5
    precondition(later.valid)
    var clockSkew = typed
    clockSkew.missions[0].decisions[2].resolvedAt = typedD1.createdAt - 100
    clockSkew.missions[0].decisions[1].createdAt = typedD1.createdAt - 200
    precondition(clockSkew.valid, "timestamps are not source append order or a native revision")
    // An answer in the gap leaves all replacement intents untouched.
    later = typed
    later.missions[0].decisions[2].closeReason = "answered"; later.missions[0].decisions[2].supersededBy = nil
    precondition(later.valid && later.missions[0].decisions[0].statusTitle == "原记录未决")
    var omittedTyped = typed
    omittedTyped.coverage = "partial"; omittedTyped.missions[0].coverage = "partial"; omittedTyped.missions[0].omitted = 1
    omittedTyped.missions[0].decisions.remove(at: 2)
    precondition(omittedTyped.valid && omittedTyped.missions[0].decisions[0].statusTitle == "原记录未决", "missing display peers do not close replacement intents")
    for field in ["closeReason", "supersedes", "supersededBy"] {
      var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(typed)) as! [String: Any]
      var missions = json["missions"] as! [[String: Any]], decisions = missions[0]["decisions"] as! [[String: Any]]
      decisions[0][field] = NSNull(); missions[0]["decisions"] = decisions; json["missions"] = missions
      let data = try JSONSerialization.data(withJSONObject: json)
      precondition((try? JSONDecoder().decode(MissionDecisionsProjection.self, from: data)) == nil, "explicit null typed field is malformed, not legacy absence")
    }
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
    snapshot.missionDecisions = typed
    precondition(snapshot.valid)
    let typedWire = WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot)
    let typedRoundtrip = try Wire.decode(Data(Wire.encode(typedWire).dropLast()))
    precondition(typedRoundtrip.snapshot?.missionDecisions == typed)
    var typedSession = session; typedSession.snapshot = snapshot
    precondition(!Presentation.needsInput(typedSession))
    snapshot.missionDecisions = nil; precondition(snapshot.valid, "legacy snapshots remain valid")
    print("Mission decision checks passed: typed replacement/withdrawal metadata, partial resolution, source-only status, no human approval, independent reporters, legacy and wire validation.")
  }
}
