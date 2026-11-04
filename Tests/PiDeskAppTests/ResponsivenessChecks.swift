import Foundation
import Combine
import PiDeskCore

@main enum ResponsivenessChecks {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var base = try Wire.decode(Data(contentsOf: root.appendingPathComponent("Fixtures/wire-v1.json"))).snapshot!
    let model = AppModel(); defer { model.stop() }
    for index in 0..<64 {
      var row = base; row.identity.nativeSessionId = "perf-session-\(index)"; row.display.name = "合成性能会话 \(index)"; row.inputs = []
      precondition(model.store.apply(WireRecord(kind: "hello", identity: row.identity, snapshot: row), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    }
    model.sessionFilter = "全部"
    model.selected = model.sessions[0].snapshot.identity.sessionKey
    let warmBuilds = model.sessionProjectionBuilds, warmSorts = model.sessionProjectionSorts
    var samples: [Double] = [], checksum = 0
    for _ in 0..<120 {
      let start = DispatchTime.now().uptimeNanoseconds
      checksum += model.sessions.count + model.visibleSessions.count + model.connectedCount + model.activeCount + model.inputCount + model.attentionCount + model.unreadResultCount
      checksum += model.current?.snapshot.seq ?? 0
      for row in model.visibleSessions { checksum += model.sessionTitle(row).utf8.count; checksum += model.workGroup(row.snapshot.identity)?.utf8.count ?? 0 }
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000000)
    }
    samples.sort()
    let report: [String: Any] = ["synthetic": true, "rows": 64, "iterations": samples.count, "projectionP50ms": samples[60], "projectionP95ms": samples[114], "projectionMaxms": samples.last!, "checksum": checksum]
    precondition(model.store.sessions.count == 64)
    precondition(model.sessionProjectionBuilds == warmBuilds && model.sessionProjectionSorts == warmSorts, "warm UI reads must not rebuild/sort unchanged sessions")
    precondition(UsageViewStateKey.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "optimized hex encoding keeps persisted SHA256 keys byte-compatible")
    precondition(UsageViewStateKey.hash("中文 · Pi") == NotificationTarget.hash("中文 · Pi"))
    // Preference/filter changes must never leave a cached list stale.
    let first = model.sessions[0].snapshot.identity
    model.search = "本机性能别名"; precondition(model.visibleSessions.isEmpty)
    precondition(model.setAlias("本机性能别名", for: first))
    precondition(model.visibleSessions.count == 1, "alias edit alone invalidates an already warm search")
    model.search = ""
    let last = model.sessions.last!.snapshot.identity
    model.togglePin(last); precondition(model.sessions[0].snapshot.identity == last)
    model.groupFilter = "性能分组"; precondition(model.visibleSessions.isEmpty)
    model.sessionGroups[UsageViewStateKey.hash(first.sessionKey)] = "性能分组"
    precondition(model.visibleSessions.count == 1, "group membership alone invalidates an already warm group filter")
    model.groupFilter = ""; model.sessionFilter = "断连"; precondition(model.visibleSessions.isEmpty)
    if let session = model.store.sessions[first.sessionKey] { model.store.disconnect(session.connectionId) }
    precondition(model.visibleSessions.count == 1 && model.visibleSessions[0].snapshot.identity == first)
    model.sessionFilter = "全部"
    let live = model.sessions.first { $0.connection == .connected }!
    let stableOrder = model.sessions.map { $0.snapshot.identity.sessionKey }
    model.search = "已更新的 Pi 原生名称"; precondition(model.visibleSessions.isEmpty)
    var changed = live.snapshot; changed.seq += 1; changed.display.name = "已更新的 Pi 原生名称"
    precondition(model.store.apply(WireRecord(kind: "snapshot", identity: changed.identity, snapshot: changed), connection: live.connectionId, now: Date().timeIntervalSince1970 * 1000))
    precondition(model.sessions.map { $0.snapshot.identity.sessionKey } == stableOrder, "status/name updates do not reshuffle enrolled rows")
    model.selected = changed.identity.sessionKey
    precondition(model.visibleSessions.count == 1 && model.current?.snapshot.seq == changed.seq, "same-key snapshot invalidates visible projection and exposes current state")
    model.search = ""
    base.identity.nativeSessionId = "perf-replacement"; base.seq += 1
    precondition(model.store.apply(WireRecord(kind: "hello", identity: base.identity, snapshot: base), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    precondition(model.sessions.contains { $0.snapshot.identity == base.identity })
    let work = try JSONDecoder().decode(GovernanceProjection.self, from: Data(contentsOf: root.appendingPathComponent("Fixtures/work-results-v1.json")))
    let reporter = model.sessions.first!
    var withWork = reporter.snapshot; withWork.seq += 1; withWork.governance = work
    precondition(model.store.apply(WireRecord(kind: "snapshot", identity: withWork.identity, snapshot: withWork), connection: reporter.connectionId, now: Date().timeIntervalSince1970 * 1000))
    precondition(model.workResults.count == 1)
    let builds = model.workResultProjectionBuilds
    for _ in 0..<120 { precondition(model.workResults.count == 1) }
    precondition(model.workResultProjectionBuilds == builds, "warm work grouping stays cached")
    withWork.seq += 1; withWork.governance = nil
    precondition(model.store.apply(WireRecord(kind: "snapshot", identity: withWork.identity, snapshot: withWork), connection: reporter.connectionId, now: Date().timeIntervalSince1970 * 1000))
    precondition(model.workResults.isEmpty, "same runtime owner reset clears the cached grouping")
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
  }
}
