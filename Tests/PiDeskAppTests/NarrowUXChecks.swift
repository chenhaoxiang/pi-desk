import Foundation
import Darwin
import PiDeskCore

private final class FakeNotifications: NotificationClient {
  var permission: AppNotificationAuthorization = .notDetermined
  var requestResult: Result<Bool, Error> = .success(false)
  var requested = 0
  var posts = 0
  var deliveryError: Error?
  var holdRequest = false
  var requestCompletion: ((Result<Bool, Error>) -> Void)?
  var activation: ((NotificationTarget) -> Void)?
  var lastTarget: NotificationTarget?
  func onActivation(_ handler: @escaping (NotificationTarget) -> Void) { activation = handler }
  func post(id: String, title: String, body: String, target: NotificationTarget?, completion: @escaping (Error?) -> Void) {
    lastTarget = target; post(id: id, title: title, body: body, completion: completion)
  }
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
  var holdViewState = false
  var stateCompletion: ((UsageViewState?, String?) -> Void)?
  var savedState: UsageViewState?
  func loadViewState(completion: @escaping (UsageViewState?, String?) -> Void) {
    if holdViewState { stateCompletion = completion } else { completion(nil, nil) }
  }
  func saveViewState(_ state: UsageViewState, completion: @escaping (String?) -> Void) { savedState = state; completion(nil) }
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
    let legacySettings = try JSONDecoder().decode(DeskSettings.self, from: Data(#"{"herdrExecutable":"","managementURL":"","notifications":false}"#.utf8))
    precondition(legacySettings.displayMode == .automatic && legacySettings.screenPolicy == "follow", "old app settings preserve default display behavior")
    var chosenDisplay = legacySettings; chosenDisplay.islandMode = IslandDisplayMode.menuOnly.rawValue; chosenDisplay.islandScreen = "display:999999"
    let restoredDisplay = try JSONDecoder().decode(DeskSettings.self, from: JSONEncoder().encode(chosenDisplay))
    precondition(restoredDisplay.displayMode == .menuOnly && restoredDisplay.screenPolicy == "display:999999", "screen choice remains saved even when a display is unavailable")
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
    let destination = NotificationTarget(identity: snapshot.identity, inputID: "input-fixture")
    let payload = destination.payload!
    precondition(NotificationTarget.decode(payload) == destination && !payload.contains(snapshot.identity.nativeSessionId) && !payload.contains(snapshot.identity.runtimeEpoch), "notification data contains hashes, not raw session identity or text")
    precondition(NotificationTarget.decode("{}") == nil)
    var opened = 0; model.showManager = { opened += 1 }
    let actionCount = model.store.requests.count
    model.activateNotification(destination, now: 1000)
    precondition(model.current?.snapshot.identity == snapshot.identity && model.page == "会话" && opened == 1 && model.store.requests.count == actionCount, "notification selects exact runtime without dispatching owner work")
    let chosenBeforeStale = model.selected
    var staleIdentity = snapshot.identity; staleIdentity.runtimeEpoch = "retired-notification-runtime"
    model.activateNotification(NotificationTarget(identity: staleIdentity), now: 2000)
    precondition(model.selected == chosenBeforeStale && model.navigationNotice?.contains("已更新") == true, "stale notification cannot select a replacement runtime")
    model.store = SessionStore(); model.selected = nil
    model.activateNotification(destination, now: 3000)
    precondition(model.current == nil && model.page == "接入健康")
    model.store = stateStore; model.resolveNotification(now: 4000)
    precondition(model.current?.snapshot.identity == snapshot.identity && model.page == "会话", "cold launch waits for exact enrollment instead of choosing any existing window")
    model.store = SessionStore(); model.activateNotification(destination, now: 5000); model.resolveNotification(now: 16000)
    precondition(model.navigationNotice?.contains("暂未重新接入") == true && model.store.requests.isEmpty)
    model.store = stateStore; model.page = "会话"; model.navigationNotice = nil
    precondition(model.healthRows.contains { $0.id == "usage" } && model.store.requests.count == actionCount, "health is a local projection, not owner polling")
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
    let live = model.current!
    let groupsBeforeRequests = model.store.requests.count
    precondition(model.assignGroups([(snapshot.identity, "官网工作")]))
    precondition(model.workGroup(snapshot.identity) == "官网工作" && model.commandEntries().contains { $0.identity == snapshot.identity && $0.matches("官网工作") })
    model.groupFilter = "another-group"
    precondition(model.visibleSessions.isEmpty && model.current == nil)
    model.select(snapshot.identity)
    precondition(model.groupFilter.isEmpty && model.current?.snapshot.identity == snapshot.identity, "navigation to an external group must reveal its exact target")
    var staleGroup = snapshot.identity; staleGroup.runtimeEpoch = "group-old-epoch"
    let groupsBefore = model.sessionGroups
    precondition(!model.assignGroups([(snapshot.identity, "should-not-partially-apply"), (staleGroup, "invalid")]) && model.sessionGroups == groupsBefore, "group changes are atomic and runtime checked")
    model.removeWorkGroup("官网工作")
    precondition(model.workGroup(snapshot.identity) == nil && model.store.requests.count == groupsBeforeRequests, "removing labels cannot stop or delete work")
    precondition(model.sessionTitle(live) != "Pi", "unnamed sessions need a stable distinguishing label")
    precondition(model.setAlias("  登录修复  ", for: snapshot.identity))
    precondition(model.sessionTitle(live) == "登录修复" && !model.setAlias("bad\nname", for: snapshot.identity))
    model.search = "登录修复"; precondition(model.visibleSessions.count == 1, "local alias must be searchable")
    model.search = ""; model.togglePin(snapshot.identity)
    precondition(model.sessions.first?.snapshot.identity == snapshot.identity && model.isPinned(snapshot.identity))
    model.togglePin(snapshot.identity); precondition(model.sessions.map { $0.snapshot.identity.sessionKey } == orderBeforeStateChange)
    precondition(model.setAlias("", for: snapshot.identity), "empty alias restores source name")
    let question = try JSONDecoder().decode(InputNotice.self, from: Data(#"{"id":"late-question","source":"fixture","kind":"question","startedAt":1000}"#.utf8))
    var largeList = (0..<64).map { index -> SessionView in
      var item = live
      item.snapshot.identity.nativeSessionId = "spotlight-\(index)"
      item.snapshot.inputs = index == 63 ? [question] : []
      return item
    }
    let spotlight = SessionExperience.spotlight(largeList, pinned: [largeList[20].snapshot.identity.sessionKey])
    precondition(spotlight.count == 4 && spotlight[0].snapshot.identity == largeList[63].snapshot.identity, "late input is not hidden behind first four sessions")
    precondition(spotlight[1].snapshot.identity == largeList[20].snapshot.identity, "pin wins over ordinary running but not input")
    let frozen = spotlight.map { $0.snapshot.identity }
    var slotStore = Dictionary(uniqueKeysWithValues: spotlight.map { ($0.snapshot.identity.sessionKey, $0) })
    var replacement = spotlight[0]; replacement.snapshot.identity.runtimeEpoch = "replacement-epoch"
    slotStore[frozen[0].sessionKey] = replacement
    let slots = SessionExperience.slots(frozen, sessions: slotStore)
    precondition(slots.count == frozen.count && slots.map(\.id) == frozen && slots[0].session == nil && slots[1].session?.snapshot.identity == frozen[1], "epoch replacement keeps an inert slot instead of shifting later click targets")
    largeList[63].connection = .disconnected
    precondition(!SessionExperience.spotlight(largeList, pinned: []).contains { $0.snapshot.identity == largeList[63].snapshot.identity }, "old disconnected input is not a live spotlight")
    let oldState = UsageViewState()
    var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldState)) as! [String: Any]
    oldJSON.removeValue(forKey: "pinnedKeyHashes"); oldJSON.removeValue(forKey: "sessionAliases")
    let migrated = try JSONDecoder().decode(UsageViewState.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    precondition(migrated.valid && migrated.pinnedKeyHashes == nil && migrated.sessionAliases == nil, "version-1 preferences remain readable")
    var resultSnapshot = snapshot
    resultSnapshot.seq += 1; resultSnapshot.execution = .settled; resultSnapshot.executionObservation?.idle = true
    resultSnapshot.activity = SessionActivity(sequence: 3, kind: "agent-settled", at: snapshot.observedAt, turnStartedAt: snapshot.observedAt - 1000, turnEndedAt: snapshot.observedAt, turnEndSequence: 3)
    var resultStore = stateStore
    precondition(resultStore.apply(WireRecord(kind: "snapshot", identity: resultSnapshot.identity, snapshot: resultSnapshot), connection: liveConnection, now: snapshot.observedAt))
    model.store = resultStore
    let result = model.store.sessions[snapshot.identity.sessionKey]!
    precondition(model.hasUnreadResult(result) && model.unreadResultCount == 1)
    var pendingResult = result; pendingResult.snapshot.pending = true
    precondition(!model.hasUnreadResult(pendingResult), "pending continuation cannot become a completed-result reminder")
    var missingProof = result; missingProof.snapshot.executionObservation = nil
    precondition(!model.hasUnreadResult(missingProof), "missing current execution proof cannot create a fresh result reminder")
    var offlineResult = result; offlineResult.connection = .disconnected
    precondition(!model.hasUnreadResult(offlineResult), "disconnected records cannot create a fresh result reminder")
    model.markResultViewed(snapshot.identity)
    precondition(!model.hasUnreadResult(result) && model.store.requests.count == requestsBefore, "viewing is display-only")
    model.reviewedResultSequences = [:]; model.selected = nil; model.sessionFilter = "需关注"; model.page = "会话"
    model.setManagerVisibility(true)
    model.select(snapshot.identity)
    precondition(model.sessionFilter == "全部" && model.current?.snapshot.identity == snapshot.identity && !model.hasUnreadResult(result), "opening an attention-only result retains its detail after marking viewed")
    model.reviewedResultSequences = [:]; model.search = "synthetic-no-match"
    model.markVisibleResultViewed(snapshot.identity)
    precondition(model.current == nil && model.hasUnreadResult(result), "a stale selection hidden by search is not a viewed detail")
    model.search = ""; model.sessionFilter = "运行中"
    model.markVisibleResultViewed(snapshot.identity)
    precondition(model.current == nil && model.hasUnreadResult(result), "settlement leaving the running filter cannot silently dismiss the new result")
    model.sessionFilter = "需关注"
    model.markVisibleResultViewed(snapshot.identity)
    precondition(model.current?.snapshot.identity == snapshot.identity && model.hasUnreadResult(result), "automatic viewing must not remove its own attention-filter detail")
    model.sessionFilter = "在线"; model.setManagerVisibility(false); model.markResultViewed(snapshot.identity)
    var newEpoch = resultSnapshot; newEpoch.identity.runtimeEpoch = "new-experience-epoch"
    precondition(model.store.apply(WireRecord(kind: "hello", identity: newEpoch.identity, snapshot: newEpoch), connection: UUID(), now: snapshot.observedAt))
    precondition(model.hasUnreadResult(model.store.sessions[newEpoch.identity.sessionKey]!), "read marker cannot cross runtimes")
    model.note("new runtime note", for: newEpoch.identity)
    model.note("must not land", for: snapshot.identity)
    precondition(model.sessionNotes[newEpoch.identity] == "new runtime note" && model.sessionNotes[snapshot.identity] == nil)
    var legacyTiming = result; legacyTiming.snapshot.activity = nil
    precondition(SessionExperience.timing(legacyTiming) == "活动时间未提供")
    precondition(SessionExperience.elapsed(since: -1) == nil)
    var invalidActivity = resultSnapshot.activity!; invalidActivity.turnEndSequence = 99
    precondition(!invalidActivity.valid)
    model.store = stateStore
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
    precondition(fake.lastTarget == NotificationTarget(identity: identity, inputID: input.id), "delivery contains the exact private navigation target")
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
    let validCalls = ledger.calls, validAggregate = model.aggregate
    model.usageCustomEnd = calendar.date(byAdding: .day, value: 400, to: today)!
    model.refreshUsage()
    precondition(!model.customRangeIsValid && model.customRangeIssue?.contains("400") == true && ledger.calls == validCalls && model.aggregate == validAggregate, "UI and ledger share the inclusive 400-day limit")
    model.usageCustomStart = today; model.usageCustomEnd = today
    model.usageComparisonEnabled = true; ledger.hold = true
    model.refreshUsage()
    let comparisonCalls = ledger.calls
    let primaryCompletion = ledger.completion!, primaryRange = ledger.range!
    primaryCompletion(.empty(primaryRange))
    precondition(model.usageLoading && ledger.calls == comparisonCalls + 1 && ledger.range == primaryRange.previousPeriod, "comparison is sequential, not a race in the coalescing ledger")
    let priorCompletion = ledger.completion!, priorRange = ledger.range!
    model.usageModel = "fixture/changed-during-comparison"; model.refreshUsage()
    priorCompletion(.empty(priorRange))
    precondition(model.usageLoading && ledger.calls == comparisonCalls + 2 && model.comparisonAggregate == nil, "stale comparison schedules latest filter without publishing old values")
    let latestMain = ledger.completion!, latestRange = ledger.range!
    latestMain(.empty(latestRange))
    let latestPrior = ledger.completion!, latestPriorRange = ledger.range!
    latestPrior(.empty(latestPriorRange))
    precondition(!model.usageLoading && model.comparisonAggregate?.selectedModel == model.usageModel && model.aggregate.selectedModel == model.usageModel)
    model.usageComparisonEnabled = false; ledger.hold = false
    // The exact menu action requests termination only. A cancelled decision must leave its UDS alive.
    await spin { model.diagnostic == "本机连接已就绪" }
    let socketArg = CommandLine.arguments.firstIndex(of: "--socket-path")!
    let socketPath = CommandLine.arguments[socketArg + 1]
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(fd >= 0)
    let peer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8) + [UInt8(0)]
    precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    precondition(connected == 0)
    var quitLive = snapshot; quitLive.identity.nativeSessionId = "quit-cancel-live"; quitLive.seq = 1; quitLive.observedAt = Date().timeIntervalSince1970 * 1000
    try peer.write(contentsOf: Wire.encode(WireRecord(kind: "hello", identity: quitLive.identity, snapshot: quitLive)))
    await spin { model.store.sessions[quitLive.identity.sessionKey]?.snapshot.seq == 1 }
    model.setDraft("keep-after-cancel", for: quitLive.identity)
    var quitRequests = 0
    model.requestTermination = { quitRequests += 1; precondition(model.requiresDraftConfirmation) }
    model.requestQuit()
    precondition(quitRequests == 1 && model.drafts[quitLive.identity] == "keep-after-cancel")
    quitLive.seq = 2; quitLive.observedAt += 1
    try peer.write(contentsOf: Wire.encode(WireRecord(kind: "snapshot", identity: quitLive.identity, snapshot: quitLive)))
    await spin { model.store.sessions[quitLive.identity.sessionKey]?.snapshot.seq == 2 }
    precondition(model.action(.message, target: Target(owner: "pi"), parameters: Parameters(text: model.drafts[quitLive.identity], mode: "followUp"), identity: quitLive.identity), "after keeping drafts the same live connection can still accept the original input")
    model.setDraft("", for: quitLive.identity)
    try peer.close()
    var modalHosts = 0
    model.showManager = { modalHosts += 1 }
    for modal in [DeskModal.commands, .drafts, .groups] {
      model.modal = nil; model.presentModal(modal)
      precondition(model.modal == modal)
    }
    precondition(modalHosts == 3, "cold/closed manager and standalone Settings commands always request a visible sheet host")
    model.stop()

    let savedKey = UsageViewStateKey.hash(snapshot.identity.sessionKey)
    var persisted = UsageViewState(); persisted.page = "Token"; persisted.sessionGroups = [savedKey: "已保存分组"]
    persisted.aiUsageCounters = ["requests": 10, "unconfirmed": 2, "input": 100, "output": 200]
    let delayed = FakeLedger(); delayed.holdViewState = true
    let recovering = AppModel(notificationClient: fake, usageLedger: delayed)
    recovering.navigate(to: "AI助手")
    delayed.stateCompletion?(persisted, nil)
    await spin { recovering.aiUsageCounters["requests"] == 10 }
    precondition(recovering.page == "AI助手" && recovering.sessionGroups == persisted.sessionGroups, "early navigation cannot erase durable organization or usage")
    recovering.flushViewState()
    precondition(delayed.savedState?.aiUsageCounters == persisted.aiUsageCounters && delayed.savedState?.sessionGroups == persisted.sessionGroups)
    recovering.stop()

    let merging = FakeLedger(); merging.holdViewState = true
    let early = AppModel(notificationClient: fake, usageLedger: merging)
    precondition(early.store.apply(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    var clearing = snapshot; clearing.identity.nativeSessionId = "clear-saved-before-load"
    precondition(early.store.apply(WireRecord(kind: "hello", identity: clearing.identity, snapshot: clearing), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    persisted.sessionGroups?[UsageViewStateKey.hash(clearing.identity.sessionKey)] = "先前标签"
    precondition(early.assignGroups([(snapshot.identity, "启动期间修改"), (clearing.identity, "")]))
    early.recordAssistantUsage(nil, unconfirmed: true)
    let numericalUsage = try JSONDecoder().decode(AssistantUsage.self, from: Data(#"{"input":10,"output":20,"cacheRead":3,"cacheWrite":0}"#.utf8))
    early.recordAssistantUsage(numericalUsage, unconfirmed: false)
    merging.stateCompletion?(persisted, nil)
    await spin { early.aiUsageCounters["requests"] == 12 }
    precondition(early.aiUsageCounters["input"] == 110 && early.aiUsageCounters["output"] == 220 && early.aiUsageCounters["unconfirmed"] == 3)
    precondition(early.workGroup(snapshot.identity) == "启动期间修改" && early.workGroup(clearing.identity) == nil, "explicit pre-load edits and removals overlay saved groups rather than replace the whole map")
    early.flushViewState()
    precondition(merging.savedState?.aiUsageCounters == early.aiUsageCounters && merging.savedState?.sessionGroups == early.sessionGroups)
    early.stop()
    print("Narrow UX checks passed: usage interest, notification/navigation, normal-quit cancellation keeps real UDS/input alive, cold modal host, delayed durable group/AI usage merge, custom ranges and stale-response preservation.")
  }
}
