import Foundation
import PiDeskCore

enum TodoChecks {
  static func run(_ base: Snapshot, root: URL) throws {
    let projection = try JSONDecoder().decode(TodoProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/todo-v1.json")))
    precondition(projection.valid && projection.counts?.total == 3 && projection.blocked.map(\.id) == [3])
    var snapshot = base; snapshot.todo = projection; snapshot.inputs = []
    var store = SessionStore(); let connection = UUID()
    precondition(store.apply(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot), connection: connection, now: snapshot.observedAt))
    let session = store.sessions[snapshot.identity.sessionKey]!
    precondition(WorkOverview.currentTask(session) == "核对当前任务与依赖")
    precondition(WorkOverview.guidance(session).contains("依赖提示") && !WorkOverview.guidance(session).contains("等待输入"))
    precondition(projection.tasks.first { $0.id == 1 }?.statusTitle == "原计划已记录完成")
    let wire = WireRecord(kind: "snapshot", identity: snapshot.identity, snapshot: snapshot)
    let roundTrip = try Wire.decode(Data(Wire.encode(wire).dropLast()))
    precondition(roundTrip.snapshot?.todo == projection)
    snapshot.todo?.counts?.total = 9; precondition(!snapshot.valid)
    snapshot.todo = projection; snapshot.todo?.tasks[0].unresolvedBy = [99]; precondition(!snapshot.valid)
    snapshot.todo = nil; precondition(snapshot.valid)
    var stale = session; stale.connection = .disconnected
    precondition(WorkOverview.currentTask(stale).contains("保留") && WorkOverview.guidance(stale).contains("不重放"))
    var omitted = projection.tasks[0]; omitted.omittedDependencies = 1
    precondition(!omitted.blocked, "omitted satisfied dependencies cannot manufacture a blocker")
    var missing = session; missing.snapshot.todo = nil
    precondition(WorkOverview.currentTask(missing) == "任务观测未接入")
    missing.snapshot.todo = projection; missing.snapshot.todo?.coverage = "not-observed"
    precondition(WorkOverview.currentTask(missing) == "当前范围任务尚未采集")
    missing.snapshot.todo?.coverage = "unavailable"
    precondition(WorkOverview.currentTask(missing) == "当前任务快照不可用")
    precondition(base.todo == nil, "legacy fixtures stay valid without task observation")
    print("Todo checks passed: shared DTO, original-plan semantics, dependency-not-human, old bridge, stale and wire validation.")
  }
}
