import Foundation
import PiDeskCore

private final class FakeNotifications: NotificationClient {
  var permission: AppNotificationAuthorization = .notDetermined
  var requestResult: Result<Bool, Error> = .success(false)
  var requested = 0
  var posts = 0
  var deliveryError: Error?
  var holdRequest = false
  var requestCompletion: ((Result<Bool, Error>) -> Void)?
  func settings(_ completion: @escaping (AppNotificationAuthorization) -> Void) { completion(permission) }
  func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void) {
    requested += 1
    if holdRequest { requestCompletion = completion } else { completion(requestResult) }
  }
  func post(id: String, title: String, body: String, completion: @escaping (Error?) -> Void) {
    precondition(title == "Pi 需要输入" && !body.contains("PRIVATE"))
    posts += 1; completion(deliveryError)
  }
}
private final class FakeLedger: UsageLedgerClient {
  var calls = 0
  var range: UsageDateRange?
  var completion: ((UsageAggregate) -> Void)?
  var hold = false
  func refresh(range: UsageDateRange, completion: @escaping (UsageAggregate) -> Void) {
    calls += 1; self.range = range
    if hold { self.completion = completion } else { completion(.empty(range, preview: true)) }
  }
}

private final class FakeTerminal: TerminalRouteActivator.Client {
  typealias Process = TerminalRouteActivator.TerminalProcess
  typealias Tab = TerminalRouteActivator.Tab
  var targets: [Process] = []
  var rows: [Tab] = []
  var chosen: [Tab] = []
  var readback = TerminalRouteActivator.Selection(windowID: 9, tty: "/dev/ttys035", frontmost: true)
  var failure: TerminalRouteActivator.Error?
  func processes() throws -> [Process] { targets }
  func tabs(in process: Process) throws -> [Tab] { if let failure { throw failure }; return rows.filter { $0.process == process } }
  func select(_ tab: Tab) throws { chosen.append(tab) }
  func selected(in process: Process) throws -> TerminalRouteActivator.Selection { readback }
}

@main enum NarrowUXChecks {
  @MainActor static func spin(_ condition: () -> Bool) async {
    for _ in 0..<100 {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    precondition(condition(), "bounded completion missing")
  }
  @MainActor static func main() async throws {
    let notificationError = NSError(domain: "UNErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_NOTIFICATION_DETAIL"])
    precondition(AppNotificationDiagnostic.detail(notificationError) == "（UNErrorDomain:1）")
    precondition(AppNotificationDiagnostic.detail(NSError(domain: "PRIVATE_DOMAIN", code: 1)).isEmpty)
    let terminal = FakeTerminal(), first = FakeTerminal.Process(pid: 10, launchedAt: 1), second = FakeTerminal.Process(pid: 11, launchedAt: 2)
    terminal.targets = [first, second]
    terminal.rows = [.init(process: first, windowID: 8, index: 1, tty: "/dev/ttys001"), .init(process: second, windowID: 9, index: 2, tty: "/dev/ttys035")]
    let focusResult = try TerminalRouteActivator.locateAndFocus(ttyPath: "/dev/ttys035", client: terminal)
    precondition(focusResult.contains("Terminal PID:11"))
    precondition(terminal.chosen.count == 1 && terminal.chosen[0].process == second, "match must span all Terminal instances, not the first bundle-default process")
    terminal.chosen = []
    func expectFocusError(_ expected: TerminalRouteActivator.Error) {
      do { _ = try TerminalRouteActivator.locateAndFocus(ttyPath: "/dev/ttys035", client: terminal); fatalError("unproven focus admitted") }
      catch { precondition(error as? TerminalRouteActivator.Error == expected) }
    }
    terminal.rows.append(.init(process: first, windowID: 7, index: 1, tty: "/dev/ttys035"))
    expectFocusError(.ambiguous); precondition(terminal.chosen.isEmpty, "ambiguity cannot mutate any window")
    terminal.rows = []; expectFocusError(.noMatch); precondition(terminal.chosen.isEmpty)
    terminal.failure = .appleEvent(-1743); expectFocusError(.appleEvent(-1743)); precondition(terminal.chosen.isEmpty, "incomplete instance enumeration cannot pick a partial match")
    terminal.failure = nil; terminal.rows = [.init(process: second, windowID: 9, index: 2, tty: "/dev/ttys035")]
    terminal.readback = .init(windowID: 10, tty: "/dev/ttys035", frontmost: true); expectFocusError(.identityMismatch)
    terminal.readback = .init(windowID: 9, tty: "/dev/ttys999", frontmost: true); expectFocusError(.identityMismatch)
    terminal.readback = .init(windowID: 9, tty: "/dev/ttys035", frontmost: false); expectFocusError(.identityMismatch)
    precondition(TerminalRouteActivator.diagnostic(TerminalRouteActivator.Error.appleEvent(-1728)).contains("-1728"))
    let fake = FakeNotifications(), ledger = FakeLedger()
    let model = AppModel(notificationClient: fake, usageLedger: ledger)
    defer { model.stop() }
    await spin { model.notificationStatus.contains("尚未授权") }
    precondition(fake.requested == 0 && fake.posts == 0, "startup must not request OS consent")
    precondition(TerminalRouteActivator.acceptsTTY("/dev/ttys035", terminalRunning: true), "strict peer TTY is sufficient without a Terminal ancestor")
    precondition(!TerminalRouteActivator.acceptsTTY("/dev/ttys035", terminalRunning: false), "do not auto-launch Terminal")
    precondition(!TerminalRouteActivator.acceptsTTY(nil, terminalRunning: true) && !TerminalRouteActivator.acceptsTTY("/dev/random", terminalRunning: true), "missing/invalid TTY stays unavailable")
    let requestsBefore = model.store.requests.count
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var snapshot = try Wire.decode(Data(contentsOf: repo.appendingPathComponent("Fixtures/wire-v1.json"))).snapshot!
    snapshot.executionObservation = try JSONDecoder().decode(ExecutionObservation.self, from: Data("{\"version\":1,\"observedAt\":\(snapshot.observedAt),\"source\":\"ctx.isIdle\",\"idle\":false}".utf8))
    var stateStore = SessionStore()
    let liveConnection = UUID()
    precondition(stateStore.apply(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot), connection: liveConnection, now: snapshot.observedAt))
    var idle = snapshot; idle.identity.nativeSessionId = "online-but-idle"; idle.execution = .settled; idle.executionObservation?.idle = true
    precondition(stateStore.apply(WireRecord(kind: "hello", identity: idle.identity, snapshot: idle), connection: UUID(), now: idle.observedAt))
    var legacy = snapshot; legacy.identity.nativeSessionId = "legacy-active-unknown"; legacy.executionObservation = nil
    precondition(stateStore.apply(WireRecord(kind: "hello", identity: legacy.identity, snapshot: legacy), connection: UUID(), now: legacy.observedAt))
    model.store = stateStore; model.search = ""; model.sessionFilter = "在线"
    let orderBeforeStateChange = model.sessions.map { $0.snapshot.identity.sessionKey }
    var settledCopy = stateStore
    var settledSnapshot = snapshot
    settledSnapshot.seq += 1; settledSnapshot.execution = .settled; settledSnapshot.executionObservation?.idle = true
    precondition(settledCopy.apply(WireRecord(kind: "snapshot", identity: settledSnapshot.identity, snapshot: settledSnapshot), connection: liveConnection, now: settledSnapshot.observedAt))
    model.store = settledCopy
    precondition(model.sessions.map { $0.snapshot.identity.sessionKey } == orderBeforeStateChange, "execution priority changes must not reorder the management list")
    model.store = stateStore
    precondition(model.visibleSessions.count == 3 && model.connectedCount == 3 && model.activeCount == 1 && model.unknownExecutionCount == 1, "online includes idle/legacy, active is a lower bound and old busy is explicitly pending")
    model.select(snapshot.identity)
    precondition(model.sectionRefreshRequestedAt.isEmpty, "ordinary row selection must not query owner status")
    model.sessionFilter = "运行中"
    precondition(model.visibleSessions.count == model.activeCount && model.visibleSessions.first?.snapshot.identity == snapshot.identity)
    snapshot.seq += 1
    snapshot.inputs = [try JSONDecoder().decode(InputNotice.self, from: Data(#"{"id":"q1","source":"fixture","kind":"question","startedAt":1000}"#.utf8)), try JSONDecoder().decode(InputNotice.self, from: Data(#"{"id":"q2","source":"fixture","kind":"question","startedAt":1000}"#.utf8))]
    precondition(model.store.apply(WireRecord(kind: "snapshot", identity: snapshot.identity, snapshot: snapshot), connection: liveConnection, now: snapshot.observedAt))
    precondition(model.activeCount == 0 && model.visibleSessions.isEmpty && model.inputCount == 1, "one waiting session is excluded from active count/filter even with multiple prompts")
    model.sessionFilter = "需输入"; precondition(model.visibleSessions.count == model.inputCount)
    model.store.disconnect(liveConnection)
    precondition(model.inputCount == 0 && model.visibleSessions.isEmpty, "disconnected old input cannot count as a current input")
    model.store = SessionStore(); model.sessionFilter = "在线"
    model.page = "Token"
    precondition(!model.managerIsVisible && model.usageRefreshInterval == 60, "no manager cannot retain the Token page's fast interest")
    let backgroundCalls = ledger.calls
    model.refreshUsageIfDue(now: Date().addingTimeInterval(6))
    precondition(ledger.calls == backgroundCalls, "hidden/minimized/closed does not query every five seconds")
    model.refreshUsageIfDue(now: Date().addingTimeInterval(61))
    precondition(ledger.calls == backgroundCalls + 1, "background keeps bounded spool indexing, not collection shutdown")
    model.setManagerVisibility(true)
    precondition(model.managerIsVisible && model.usageRefreshInterval == 5)
    model.refreshUsageIfDue(now: Date().addingTimeInterval(6))
    precondition(ledger.calls == backgroundCalls + 2)
    model.page = "会话"
    precondition(model.usageRefreshInterval == 30)
    model.setManagerVisibility(false)
    precondition(model.usageRefreshInterval == 60)
    model.page = "Token"
    precondition(model.usageRefreshInterval == 60, "retained page does not override actual window interest")
    fake.permission = .authorized; fake.requestResult = .success(true)
    model.enableNotifications()
    await spin { model.notificationStatus.contains("已授权") && !model.requestingNotifications }
    precondition(fake.requested == 1 && model.settings.notifications)
    fake.permission = .denied
    model.checkNotificationStatus()
    await spin { model.notificationStatus.contains("已拒绝") }
    fake.requestResult = .success(false)
    model.enableNotifications()
    await spin { model.notificationStatus.contains("未获授权") }
    fake.requestResult = .failure(AppNotificationError.requestFailed)
    model.enableNotifications()
    await spin { model.notificationStatus.contains("开启系统通知失败") }
    fake.holdRequest = true
    model.enableNotifications(); model.enableNotifications()
    precondition(fake.requested == 4 && model.requestingNotifications, "only one in-flight explicit request")
    fake.requestCompletion?(.failure(AppNotificationError.requestFailed))
    await spin { !model.requestingNotifications }
    let input = try JSONDecoder().decode(InputNotice.self, from: Data(#"{"id":"fixture-input","source":"fixture","kind":"input","startedAt":1000}"#.utf8))
    let identity = Identity(localHostId: "fixture", nativeSessionId: "session", runtimeEpoch: "epoch")
    fake.permission = .authorized; fake.deliveryError = AppNotificationError.deliveryFailed
    model.sendNotification(for: input, session: identity)
    await spin { model.notificationStatus.contains("发送失败") }
    precondition(fake.posts == 1 && model.store.requests.count == requestsBefore, "display failure cannot send execution actions")
    fake.permission = .denied
    model.sendNotification(for: input, session: identity)
    await spin { model.notificationStatus.contains("已拒绝") }
    precondition(fake.posts == 1 && model.store.requests.count == requestsBefore)
    model.usagePreset = .custom
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
    let today = calendar.startOfDay(for: Date())
    model.usageCustomStart = today; model.usageCustomEnd = today
    model.refreshUsage()
    let previous = model.aggregate, previousCalls = ledger.calls
    model.usageCustomStart = calendar.date(byAdding: .day, value: 1, to: today)!
    model.refreshUsage()
    precondition(!model.customRangeIsValid && ledger.calls == previousCalls && model.aggregate == previous)
    precondition(model.actionNote.contains("未查询新范围"))
    // In-flight response from a previously valid range must not replace the result after fields become invalid.
    model.usageCustomStart = today; ledger.hold = true; model.refreshUsage()
    let inFlightRange = ledger.range!
    model.usageCustomEnd = calendar.date(byAdding: .day, value: -1, to: today)!
    model.refreshUsage()
    let heldCalls = ledger.calls
    ledger.completion?(.empty(inFlightRange))
    precondition(!model.usageLoading && model.aggregate == previous && ledger.calls == heldCalls)
    // Start/end are calendar dates: earlier clock time on the same day remains a valid day range.
    model.usageCustomStart = today.addingTimeInterval(12 * 3600); model.usageCustomEnd = today
    ledger.hold = false; model.refreshUsage()
    precondition(model.customRangeIsValid && ledger.calls == heldCalls + 1)
    print("Narrow UX checks passed: visible/background usage interest, explicit authorization only, authorized/denied/error/send-failure, duplicate request, invalid custom range and stale in-flight preservation.")
  }
}
