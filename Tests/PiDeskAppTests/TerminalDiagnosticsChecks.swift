import Foundation
import PiDeskCore
@testable import PiDeskTransport

private final class EmptyRouteLedger: UsageLedgerClient {
  func refresh(range: UsageDateRange, completion: @escaping (UsageAggregate) -> Void) { completion(.empty(range, preview: true)) }
}
@MainActor private final class FakeRouteAccess {
  var permissionText = "终端Automation已拒绝；请由用户在系统设置检查权限"
  var permissionCalls: [Bool] = []
  var focusCalls: [String] = []
  var peerInfo: PeerProcessInfo?
  var holdPermission = false
  var holdFocus = false
  var permissionWaiters: [CheckedContinuation<String,Never>] = []
  var focusWaiters: [CheckedContinuation<String,Error>] = []
  var focusError: TerminalRouteActivator.Error? = .appleEvent(-1728)
  var access: TerminalRouteAccess {
    TerminalRouteAccess(isRunning: { true }, permission: { consent in
      self.permissionCalls.append(consent)
      if self.holdPermission { return await withCheckedContinuation { self.permissionWaiters.append($0) } }
      return self.permissionText
    }, focus: { tty in
      self.focusCalls.append(tty)
      if self.holdFocus { return try await withCheckedThrowingContinuation { self.focusWaiters.append($0) } }
      if let error = self.focusError { throw error }
      return "Synthetic unique Terminal/TTY readback"
    }, peerInfo: { _, completion in completion(self.peerInfo) })
  }
}
@main enum TerminalDiagnosticsChecks {
  @MainActor static func spin(_ condition: () -> Bool) async {
    for _ in 0..<200 { if condition() { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
    precondition(condition(), "bounded completion missing")
  }
  @MainActor static func drain() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 2_000_000) }
  @MainActor static func main() async throws {
    let denied = "终端Automation已拒绝；请由用户在系统设置检查权限", allowed = "终端Automation已授权"
    let fake = FakeRouteAccess()
    let subject = AppModel(usageLedger: EmptyRouteLedger(), terminalAccess: fake.access)
    defer { subject.stop() }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var snapshot = try Wire.decode(Data(contentsOf: repo.appendingPathComponent("Fixtures/wire-v1.json"))).snapshot!
    snapshot.display.route = Route(kind: "terminal", sessionId: snapshot.identity.nativeSessionId, ttyPath: "/dev/ttys035", terminalApp: "com.apple.Terminal")
    var connection = UUID()
    func publish(_ hello: Bool = false) {
      snapshot.seq += 1; snapshot.observedAt += 1
      subject.consume(.record(WireRecord(kind: hello ? "hello" : "snapshot", identity: snapshot.identity, snapshot: snapshot), connection))
    }
    publish(true)
    var sibling = snapshot; sibling.identity.nativeSessionId = "other-terminal-session"; sibling.display.route = nil
    let siblingConnection = UUID()
    subject.consume(.record(WireRecord(kind: "hello", identity: sibling.identity, snapshot: sibling), siblingConnection))
    sibling.seq += 1; sibling.display.route = Route(kind: "terminal", sessionId: sibling.identity.nativeSessionId, ttyPath: "/dev/ttys045", terminalApp: "com.apple.Terminal")
    subject.consume(.record(WireRecord(kind: "snapshot", identity: sibling.identity, snapshot: sibling), siblingConnection))
    await drain()
    precondition(subject.routeNotes[sibling.identity]?.contains("当前快照已提供") == true, "late fallback lookup cannot erase a new explicit route")
    precondition(fake.permissionCalls.isEmpty && fake.focusCalls.isEmpty, "snapshots and startup must not check/request permission or focus")
    // Legacy bridges omit route on every snapshot. Their same-connection fallback
    // remains scoped and must survive a refresh followed by the next heartbeat.
    var legacy = snapshot; legacy.identity.nativeSessionId = "legacy-terminal-session"; legacy.display.route = nil
    let legacyConnection = UUID()
    fake.peerInfo = PeerProcessInfo(pid: 123, parentPID: 1, ttyPath: "/dev/ttys055", startSeconds: 1, startMicroseconds: 2, terminalPID: nil)
    subject.consume(.record(WireRecord(kind: "hello", identity: legacy.identity, snapshot: legacy), legacyConnection))
    await spin { subject.store.sessions[legacy.identity.sessionKey]?.snapshot.display.route?.ttyPath == "/dev/ttys055" }
    subject.openOriginal(identity: legacy.identity)
    await spin { subject.locationDiagnostics[legacy.identity] != nil }
    let legacyPermission = subject.permissionDiagnostics[legacy.identity]!, legacyResult = subject.locationDiagnostics[legacy.identity]!
    for refresh in [false, true] {
      if refresh { subject.refreshOriginalRoute(identity: legacy.identity) }
      legacy.seq += 1; legacy.observedAt += 1
      subject.consume(.record(WireRecord(kind: "snapshot", identity: legacy.identity, snapshot: legacy), legacyConnection))
      await drain()
      precondition(subject.permissionDiagnostics[legacy.identity] == legacyPermission && subject.locationDiagnostics[legacy.identity] == legacyResult, "legacy heartbeat/refresh must retain same-scope permission and locating records")
    }
    subject.consume(.disconnected(legacyConnection)); fake.peerInfo = nil
    subject.checkOriginalRoutePermission(identity: snapshot.identity)
    await spin { subject.permissionDiagnostics[snapshot.identity]?.message == denied }
    let check = subject.permissionDiagnostics[snapshot.identity]!
    for _ in 0..<3 { publish() }
    precondition(subject.permissionDiagnostics[snapshot.identity] == check, "ordinary snapshots retain concrete permission failure and its original time")
    precondition(subject.routeNotes[snapshot.identity]?.contains("TTY") == true && subject.routeNotes[snapshot.identity] != denied, "route existence is separate from permission")
    precondition(subject.locationDiagnostics[snapshot.identity] == nil, "permission check is not a focus result")
    subject.openOriginal(identity: snapshot.identity)
    await spin { subject.locationDiagnostics[snapshot.identity] != nil }
    let rejected = subject.locationDiagnostics[snapshot.identity]!
    precondition(rejected.message.contains(denied) && fake.focusCalls.isEmpty)
    publish(); subject.refreshOriginalRoute(identity: snapshot.identity)
    precondition(subject.locationDiagnostics[snapshot.identity] == rejected)
    precondition(subject.permissionDiagnostics[snapshot.identity]?.message == denied)
    fake.permissionText = allowed
    subject.openOriginal(identity: snapshot.identity)
    await spin { subject.locationDiagnostics[snapshot.identity]?.message.contains("-1728") == true }
    let focusFailure = subject.locationDiagnostics[snapshot.identity]!, allowedCheck = subject.permissionDiagnostics[snapshot.identity]!
    publish(); publish()
    precondition(subject.locationDiagnostics[snapshot.identity] == focusFailure && subject.permissionDiagnostics[snapshot.identity] == allowedCheck)
    precondition(fake.focusCalls.count == 1)
    // A displayed allowed check is historical only. Every new focus preflights again.
    fake.permissionText = denied; let checksBefore = fake.permissionCalls.count
    subject.openOriginal(identity: snapshot.identity)
    await spin { subject.locationDiagnostics[snapshot.identity]?.message.contains(denied) == true }
    precondition(fake.permissionCalls.count == checksBefore + 1 && fake.focusCalls.count == 1)
    snapshot.display.route?.ttyPath = "/dev/ttys036"; publish()
    precondition(subject.permissionDiagnostics[snapshot.identity] == nil && subject.locationDiagnostics[snapshot.identity] == nil && subject.sessionNotes[snapshot.identity] == nil, "route change invalidates scoped observations, including route-specific banner")
    // Same native runtime can reconnect with a different connection; its old read
    // must not write into the replacement, even when identity and route match.
    fake.holdPermission = true
    subject.checkOriginalRoutePermission(identity: snapshot.identity)
    await spin { fake.permissionWaiters.count == 1 }
    connection = UUID(); publish(true)
    fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[snapshot.identity] == nil)
    // Route A -> B -> A still invalidates the original operation token.
    subject.checkOriginalRoutePermission(identity: snapshot.identity)
    await spin { fake.permissionWaiters.count == 1 }
    snapshot.display.route?.ttyPath = "/dev/ttys037"; publish(); snapshot.display.route?.ttyPath = "/dev/ttys036"; publish()
    fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[snapshot.identity] == nil)
    // The complete route participates, not just its kind and TTY.
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    snapshot.display.route?.cwd = "/synthetic/changed-route"; publish()
    fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[snapshot.identity] == nil)
    // Changing the selected row is not changing the request's recipient.
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    subject.select(sibling.identity)
    fake.permissionWaiters.removeFirst().resume(returning: denied)
    await spin { subject.permissionDiagnostics[snapshot.identity]?.message == denied }
    precondition(subject.permissionDiagnostics[sibling.identity] == nil && subject.selected == sibling.identity.sessionKey)
    // A new check wins over a late prior check in the same exact scope.
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 2 }
    let first = fake.permissionWaiters.removeFirst(), second = fake.permissionWaiters.removeFirst()
    second.resume(returning: allowed); await spin { subject.permissionDiagnostics[snapshot.identity]?.message == allowed }
    let latest = subject.permissionDiagnostics[snapshot.identity]!
    first.resume(returning: denied); await drain(); precondition(subject.permissionDiagnostics[snapshot.identity] == latest)
    // A later manual check supersedes an in-flight focus preflight. It cannot
    // promote the older allowed response into a new focus action.
    let beforeSupersededFocus = fake.focusCalls.count
    subject.openOriginal(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 2 }
    let preflight = fake.permissionWaiters.removeFirst(), manual = fake.permissionWaiters.removeFirst()
    manual.resume(returning: denied); await spin { subject.permissionDiagnostics[snapshot.identity]?.message == denied }
    preflight.resume(returning: allowed); await spin { subject.locationDiagnostics[snapshot.identity]?.message.contains("较新权限检查") == true }
    precondition(fake.focusCalls.count == beforeSupersededFocus && subject.permissionDiagnostics[snapshot.identity]?.message == denied)
    // A permission denial returned by a focus preflight after reconnect must not
    // create the old generic banner or a permission result for the new socket.
    subject.openOriginal(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    connection = UUID(); publish(true)
    fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[snapshot.identity] == nil && subject.locationDiagnostics[snapshot.identity] == nil && subject.sessionNotes[snapshot.identity] == nil)
    // A late allowed preflight also cannot activate a changed target.
    let focusedBefore = fake.focusCalls.count
    subject.openOriginal(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    snapshot.display.route?.ttyPath = "/dev/ttys038"; publish()
    fake.permissionWaiters.removeFirst().resume(returning: allowed); await drain()
    precondition(fake.focusCalls.count == focusedBefore)
    fake.holdPermission = false; fake.permissionText = allowed; fake.holdFocus = true
    subject.openOriginal(identity: snapshot.identity); await spin { fake.focusWaiters.count == 1 }
    snapshot.display.route?.ttyPath = "/dev/ttys039"; publish()
    fake.focusWaiters.removeFirst().resume(returning: "Synthetic old success"); await drain()
    precondition(subject.locationDiagnostics[snapshot.identity] == nil && subject.sessionNotes[snapshot.identity] == nil, "old focus result cannot mark a changed route successful")
    // Latest explicit locating request wins even if an older completion arrives last.
    subject.openOriginal(identity: snapshot.identity); await spin { fake.focusWaiters.count == 1 }
    subject.openOriginal(identity: snapshot.identity); await spin { fake.focusWaiters.count == 2 }
    let olderFocus = fake.focusWaiters.removeFirst(), newerFocus = fake.focusWaiters.removeFirst()
    newerFocus.resume(returning: "Synthetic newer focus"); await spin { subject.locationDiagnostics[snapshot.identity]?.message.contains("newer focus") == true }
    let newestFocus = subject.locationDiagnostics[snapshot.identity]!
    olderFocus.resume(throwing: TerminalRouteActivator.Error.appleEvent(-1728)); await drain()
    precondition(subject.locationDiagnostics[snapshot.identity] == newestFocus)
    // Epoch change and disconnect fence both read and result delivery.
    fake.holdFocus = false; fake.holdPermission = true
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    let oldIdentity = snapshot.identity; snapshot.identity.runtimeEpoch = "new-terminal-epoch"; publish(true)
    fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[oldIdentity] == nil && subject.permissionDiagnostics[snapshot.identity] == nil)
    subject.checkOriginalRoutePermission(identity: snapshot.identity); await spin { fake.permissionWaiters.count == 1 }
    subject.consume(.disconnected(connection))
    fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[snapshot.identity] == nil && subject.locationDiagnostics[snapshot.identity] == nil)
    precondition(fake.permissionCalls.allSatisfy { !$0 }, "no implicit consent request")
    connection = UUID(); publish(true)
    // Only an explicit requestConsent=true call reaches the original opt-in.
    fake.holdPermission = false; fake.permissionText = allowed
    subject.checkOriginalRoutePermission(identity: snapshot.identity, requestConsent: true)
    await spin { subject.permissionDiagnostics[snapshot.identity]?.message == allowed }
    precondition(fake.permissionCalls.filter { $0 }.count == 1)
    // Stop fences pending readback without touching the real permission system.
    fake.holdPermission = true; subject.checkOriginalRoutePermission(identity: snapshot.identity)
    await spin { fake.permissionWaiters.count == 1 }
    let beforeStop = subject.permissionDiagnostics[snapshot.identity]
    subject.stop(); fake.permissionWaiters.removeFirst().resume(returning: denied); await drain()
    precondition(subject.permissionDiagnostics[snapshot.identity] == beforeStop)
    print("Terminal diagnostics checks passed: snapshot-stable permission/result/time, exact connection/route/runtime fencing, ABA/late denial/late success/latest-check guards, no cached authorization or automatic consent.")
  }
}
