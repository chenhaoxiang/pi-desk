import AppKit
import Darwin
import Foundation
import PiDeskCore
import PiDeskTransport
import SwiftUI
import UserNotifications

enum BuildIdentity {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "development"
  }
  static var source: String {
    Bundle.main.object(forInfoDictionaryKey: "PiDeskSourceRevision") as? String ?? "unbundled"
  }
  static var channel: String {
    Bundle.main.object(forInfoDictionaryKey: "PiDeskBuildChannel") as? String ?? "development"
  }
  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
  }
  static var label: String {
    "Pi Desk \(version) · \(channel) build \(build) · source \(source.prefix(12))"
  }
}
struct VisualFixture: Decodable {
  let synthetic: Bool
  let records: [WireRecord]
  let connections: [String: String]?
}
struct DeskSettings: Codable {
  var herdrExecutable = ""
  var managementURL = ""
  var notifications = false
}
@MainActor final class AppModel: ObservableObject {
  @Published var store = SessionStore()
  @Published var selected: String?
  @Published var page = "会话"
  @Published var diagnostic = "连接正在启动"
  @Published var actionNote = ""
  @Published var settings = DeskSettings()
  @Published var dismissed: Set<String> = []
  @Published var muted = false
  @Published var drafts: [Identity: String] = [:]
  @Published var search = ""
  @Published var searchFocusRequest = 0
  @Published var sessionFilter = "在线"
  @Published var hiddenSessions: Set<String> = []
  @Published var usagePreset: UsagePreset = .today
  @Published var usageMetric: UsageMetric = .interaction
  @Published var usageModel = ""
  @Published var usageOrigin: UsageOrigin = .combined
  @Published var usageCustomStart = Date()
  @Published var usageCustomEnd = Date()
  @Published var aggregate = UsageAggregate.empty(.make(preset: .today))
  @Published var usageLoading = false
  @Published var notificationStatus = "尚未检查系统通知状态"
  @Published var requestingNotifications = false
  @Published var notificationsAuthorized = false
  @Published var sectionRefreshRequestedAt: [Identity: Date] = [:]
  @Published var piSettingsSnapshot: PiSettingsSnapshot?
  @Published var piSettingsSelections: [String: String] = [:]
  @Published var piSettingsLoading = false
  @Published var piSettingsNote = "尚未读取原Pi设置"
  private let piSettingsStore = PiSettingsStore()
  private var piSettingsGeneration = UUID()
  var piSettingsChanges: [String: String] {
    guard let snapshot = piSettingsSnapshot else { return [:] }
    return piSettingsSelections.filter { key, value in value != "__keep__" && value != (snapshot.values[key] ?? PiSettingsStore.unset) }
  }
  func reloadPiSettings(projectCwd: String? = nil) {
    guard !isPreview else { piSettingsNote = "合成预览不读取或修改真实Pi设置"; return }
    piSettingsGeneration = UUID(); let generation = piSettingsGeneration
    piSettingsLoading = true
    piSettingsStore.load(projectCwd: projectCwd ?? current?.snapshot.display.cwd) { [weak self] result in
      Task { @MainActor in
        guard let self, self.piSettingsGeneration == generation else { return }
        self.piSettingsLoading = false
        switch result {
        case .success(let snapshot):
          self.piSettingsSnapshot = snapshot
          self.piSettingsSelections = Dictionary(uniqueKeysWithValues: PiSettingField.fields.map { field in
            (field.key, snapshot.values[field.key].map { field.choices.contains($0) ? $0 : "__keep__" } ?? PiSettingsStore.unset)
          })
          self.piSettingsNote = "已读取原Pi用户设置；点击保存前不修改任何文件。"
        case .failure(let error): self.piSettingsSnapshot = nil; self.piSettingsNote = error.rawValue
        }
      }
    }
  }
  func savePiSettings() {
    guard !isPreview, !piSettingsLoading, let snapshot = piSettingsSnapshot, !piSettingsChanges.isEmpty else { return }
    piSettingsLoading = true; let generation = piSettingsGeneration
    piSettingsStore.save(changes: piSettingsChanges, expected: snapshot) { [weak self] result in
      Task { @MainActor in
        guard let self, self.piSettingsGeneration == generation else { return }
        self.piSettingsLoading = false
        switch result {
        case .success(let value):
          self.piSettingsSnapshot = value
          self.piSettingsNote = "已原子保存到原Pi用户设置并读回，备份保留；下次会话生效，未reload当前会话。"
        case .failure(let error): self.piSettingsNote = error.rawValue
        }
      }
    }
  }
  private let notificationClient: NotificationClient?
  private var ledger: UsageLedgerClient?
  private var lastUsageRefresh = Date.distantPast
  private(set) var managerIsVisible = false
  private var viewStateLoaded = false
  private var viewStateTouchedBeforeLoad = false
  private var restoringViewState = false
  private var selectionPinned = false
  private var pendingSelectionHash: String?
  private var pendingHiddenHashes = Set<String>()
  private var pendingDismissedHashes = Set<String>()
  private var viewStateSaveWork: DispatchWorkItem?
  var usageRefreshInterval: TimeInterval { managerIsVisible ? (page == "Token" ? 5 : 30) : 60 }
  func setManagerVisibility(_ visible: Bool) {
    guard visible != managerIsVisible else { return }
    managerIsVisible = visible
    if visible && page == "Token" && Date().timeIntervalSince(lastUsageRefresh) >= 1 { refreshUsage() }
  }
  func refreshUsageIfDue(now: Date = Date()) {
    if now.timeIntervalSince(lastUsageRefresh) >= usageRefreshInterval { refreshUsage() }
  }
  private var ownerQueryTimes: [String: Date] = [:]
  let isPreview: Bool
  var showManager: () -> Void = {}
  var showIsland: () -> Void = {}
  func setDraft(_ value: String, for identity: Identity) {
    if drafts.count >= 64 && drafts[identity] == nil {
      drafts.removeValue(forKey: drafts.keys.first!)
    }
    drafts[identity] = value
  }
  func navigate(to page: String) {
    self.page = ["会话", "Token", "重要事项", "设置"].contains(page) ? page : "会话"
    showManager(); persistViewState()
  }
  func focusSessionSearch() { navigate(to: "会话"); searchFocusRequest += 1 }
  func nextAttentionSession() {
    let candidates = sessions.filter { session in
      session.connection == .connected && (session.snapshot.execution == .failed || session.snapshot.inputs.contains { !isRead($0, session: session.snapshot.identity) })
    }
    guard !candidates.isEmpty else { actionNote = "当前没有未读需关注会话"; return }
    let index = selected.flatMap { key in candidates.firstIndex { $0.snapshot.identity.sessionKey == key } }.map { ($0 + 1) % candidates.count } ?? 0
    page = "会话"; select(candidates[index].snapshot.identity, refreshOwner: false); showManager()
  }
  func select(_ identity: Identity, refreshOwner: Bool = true) {
    guard store.sessions[identity.sessionKey]?.snapshot.identity == identity else { return }
    if !visibleSessions.contains(where: { $0.snapshot.identity == identity }) {
      search = ""
      sessionFilter = "全部"
      hiddenSessions.remove(identity.sessionKey)
    }
    selected = identity.sessionKey
    selectionPinned = true
    pendingSelectionHash = UsageViewStateKey.hash(identity.sessionKey)
    persistViewState()
    if refreshOwner { refresh(identity: identity) }
  }
  private func preferredSessionKey() -> String? {
    if let pendingSelectionHash,
      let restored = sessions.first(where: { UsageViewStateKey.hash($0.snapshot.identity.sessionKey) == pendingSelectionHash }) {
      return restored.snapshot.identity.sessionKey
    }
    let connected = sessions.filter { $0.connection == .connected }
    let input = connected.first(where: { !$0.snapshot.inputs.isEmpty })
    if let input { return input.snapshot.identity.sessionKey }
    let active = connected.first(where: { Presentation.isExecutionActive($0) })
    return active?.snapshot.identity.sessionKey ?? connected.first?.snapshot.identity.sessionKey ?? sessions.first?.snapshot.identity.sessionKey
  }
  func selectPreferredSession() {
    guard !selectionPinned, let key = preferredSessionKey() else { return }
    if selected != key { selected = key }
  }
  private func restoreHidden(_ identity: Identity, connection: ConnectionState) {
    guard connection != .connected, pendingHiddenHashes.contains(UsageViewStateKey.hash(identity.sessionKey)) else { return }
    hiddenSessions.insert(identity.sessionKey)
  }
  private func applyViewState(_ state: UsageViewState?) {
    guard let stored = state, stored.valid else { return }
    let state = stored.migratedNavigation
    restoringViewState = true
    defer { restoringViewState = false }
    if let value = UsagePreset(rawValue: state.usagePreset) { usagePreset = value }
    if let value = UsageMetric(rawValue: state.usageMetric) { usageMetric = value }
    if let value = UsageOrigin(rawValue: state.usageOrigin) { usageOrigin = value }
    page = state.page
    if ["在线", "全部", "运行中", "需输入", "断连"].contains(state.sessionFilter) { sessionFilter = state.sessionFilter }
    usageModel = state.usageModel
    if let start = state.customStartMS { usageCustomStart = Date(timeIntervalSince1970: Double(start) / 1000) }
    if let end = state.customEndMS { usageCustomEnd = Date(timeIntervalSince1970: Double(end) / 1000) }
    pendingSelectionHash = state.selectedKeyHash
    pendingHiddenHashes = Set(state.hiddenKeyHashes)
    pendingDismissedHashes = Set(state.dismissedKeyHashes)
    for session in sessions where session.connection != .connected && pendingHiddenHashes.contains(UsageViewStateKey.hash(session.snapshot.identity.sessionKey)) {
      hiddenSessions.insert(session.snapshot.identity.sessionKey)
    }
  }
  private func currentViewState() -> UsageViewState {
    var state = UsageViewState()
    state.page = page; state.sessionFilter = sessionFilter
    state.usagePreset = usagePreset.rawValue; state.usageMetric = usageMetric.rawValue
    state.usageOrigin = usageOrigin.rawValue; state.usageModel = usageModel
    state.customStartMS = Int64(usageCustomStart.timeIntervalSince1970 * 1000)
    state.customEndMS = Int64(usageCustomEnd.timeIntervalSince1970 * 1000)
    state.selectedKeyHash = selectionPinned ? selected.map { UsageViewStateKey.hash($0) } : pendingSelectionHash
    state.hiddenKeyHashes = Array(pendingHiddenHashes.union(hiddenSessions.map { UsageViewStateKey.hash($0) })).sorted().prefix(64).map { $0 }
    state.dismissedKeyHashes = Array(pendingDismissedHashes.union(dismissed.map { UsageViewStateKey.hash($0) })).sorted().prefix(1024).map { $0 }
    return state
  }
  func persistViewState() {
    guard !isPreview, !restoringViewState else { return }
    guard viewStateLoaded else { viewStateTouchedBeforeLoad = true; return }
    viewStateSaveWork?.cancel()
    let state = currentViewState()
    let work = DispatchWorkItem { [weak self] in
      self?.ledger?.saveViewState(state) { [weak self] issue in
        guard let issue else { return }
        Task { @MainActor in self?.actionNote = issue }
      }
    }
    viewStateSaveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }
  func flushViewState() {
    viewStateSaveWork?.cancel(); viewStateSaveWork = nil
    guard viewStateLoaded, !isPreview, let ledger else { return }
    if !ledger.flushViewState(currentViewState()) { actionNote = "视图状态退出写入未确认；本次状态保留在内存，旧SQLite数据未覆盖" }
  }
  private var notified: Set<String> = []
  private struct PeerRouteBinding {
    let connection: UUID
    let process: PeerProcessInfo
    let route: Route
  }
  @Published private(set) var routeNotes: [Identity: String] = [:]
  private var peerRoutes: [Identity: PeerRouteBinding] = [:]
  private var routeAttempts: [UUID: Identity] = [:]
  private var server: SocketServer!
  func checkOriginalRoutePermission(identity: Identity, requestConsent: Bool = false) {
    Task {
      let status = await TerminalRouteActivator.permissionStatus(requestConsent: requestConsent)
      guard store.sessions[identity.sessionKey]?.snapshot.identity == identity else { return }
      routeNotes[identity] = status
    }
  }
  func refreshOriginalRoute(identity: Identity) {
    guard let session = store.sessions[identity.sessionKey], session.snapshot.identity == identity else { return }
    routeAttempts.removeValue(forKey: session.connectionId)
    peerRoutes.removeValue(forKey: identity)
    resolveOriginalRoute(session)
  }
  private func resolveOriginalRoute(_ session: SessionView) {
    let identity = session.snapshot.identity, connection = session.connectionId
    guard !isPreview, session.connection == .connected else { routeNotes[identity] = "会话已断开；不会聚焦最后一次旧路由"; return }
    if let binding = peerRoutes[identity], binding.connection == connection {
      _ = store.updateRoute(binding.route, identity: identity, connection: connection)
      return
    }
    guard routeAttempts[connection] != identity else { return }
    if let route = session.snapshot.display.route, route.kind == "terminal", route.terminalApp == "com.apple.Terminal", route.ttyPath != nil { routeNotes[identity] = "桥接已提供精确Terminal TTY"; return }
    if session.snapshot.display.route?.kind == "herdr" && !settings.herdrExecutable.isEmpty { return }
    routeAttempts[connection] = identity
    routeNotes[identity] = "正在从当前连接解析终端；无需重载Pi"
    server.peerProcessInfo(connection) { [weak self] info in
      Task { @MainActor in
        guard let self, let current = self.store.sessions[identity.sessionKey], current.connectionId == connection, current.snapshot.identity == identity, current.connection == .connected else { return }
        guard let info else { self.routeNotes[identity] = "无法核验连接进程或出生时间；未采用旧PID"; return }
        guard let tty = info.ttyPath else { self.routeNotes[identity] = "当前Pi进程没有controlling TTY；可能是非终端宿主"; return }
        guard TerminalRouteActivator.acceptsTTY(tty, terminalRunning: TerminalRouteActivator.isTerminalRunning()) else { self.routeNotes[identity] = "已核验TTY，但Terminal.app未运行；不会自动启动终端"; return }
        let route = Route(kind: "terminal", sessionId: identity.nativeSessionId, cwd: current.snapshot.display.cwd, ttyPath: tty, terminalApp: "com.apple.Terminal")
        self.peerRoutes[identity] = PeerRouteBinding(connection: connection, process: info, route: route)
        _ = self.store.updateRoute(route, identity: identity, connection: connection)
        self.routeNotes[identity] = info.terminalPID == nil ? "已核验TTY；Terminal.app祖先不可从进程树确认，focus时用唯一TTY回读" : "已从当前连接核验Terminal TTY（兼容旧桥接）"
      }
    }
  }
  private var timer: Timer?
  private let settingsURL: URL
  let socketPath: String
  var sessions: [SessionView] {
    store.sessions.values.sorted {
      let a = Presentation.priority($0)
      let b = Presentation.priority($1)
      return a == b ? $0.snapshot.display.name < $1.snapshot.display.name : a < b
    }
  }
  var current: SessionView? { selected.flatMap { key in visibleSessions.first { $0.snapshot.identity.sessionKey == key } } }
  var visibleSessions: [SessionView] {
    sessions.filter { s in
      let snap = s.snapshot
      let matchesSearch = search.isEmpty || [snap.display.name, Presentation.project(snap), snap.display.branch ?? "", snap.display.model ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search)
      let matchesState = sessionFilter == "在线" ? s.connection == .connected : sessionFilter == "全部" || (sessionFilter == "运行中" && Presentation.isExecutionActive(s)) || (sessionFilter == "需输入" && Presentation.needsInput(s)) || (sessionFilter == "断连" && s.connection != .connected)
      return matchesSearch && matchesState && (!hiddenSessions.contains(snap.identity.sessionKey) || s.connection == .connected)
    }
  }
  func hideDisconnected(_ identity: Identity) {
    guard let s = store.sessions[identity.sessionKey], s.snapshot.identity == identity, s.connection != .connected else { return }
    hiddenSessions.insert(identity.sessionKey)
    if selected == identity.sessionKey { selected = visibleSessions.first?.snapshot.identity.sessionKey }
    persistViewState()
    actionNote = "仅隐藏断连卡片，未停止或删除任何Pi工作"
  }
  func clearHiddenSessions() {
    hiddenSessions.removeAll(); pendingHiddenHashes.removeAll()
    persistViewState()
  }
  var customRangeIsValid: Bool {
    guard usagePreset == .custom else { return true }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.startOfDay(for: usageCustomEnd) >= calendar.startOfDay(for: usageCustomStart)
  }
  func refreshUsage() {
    guard customRangeIsValid else {
      actionNote = "结束日期早于开始日期，未查询新范围；请先调整日期"
      return
    }
    let range = UsageDateRange.make(preset: usagePreset, customStart: usageCustomStart, customEnd: usageCustomEnd)
    if isPreview { aggregate = UsageAggregate.empty(range, preview: true).filtered(origin:usageOrigin,model: usageModel.isEmpty ? nil : usageModel); return }
    guard !usageLoading, let ledger else { return }
    usageLoading = true; lastUsageRefresh = Date()
    let filter = usageModel.isEmpty ? nil : usageModel
    ledger.refresh(range: range, model: filter, origin:usageOrigin) { [weak self] result in
      guard let self else { return }
      self.usageLoading = false
      guard self.customRangeIsValid else { return }
      let expected = UsageDateRange.make(preset: self.usagePreset, customStart: self.usageCustomStart, customEnd: self.usageCustomEnd)
      guard expected == result.range, self.usageOrigin == result.selectedOrigin, (self.usageModel.isEmpty ? nil : self.usageModel) == result.selectedModel else { self.refreshUsage(); return }
      if result.error != nil, self.aggregate.totals.seen, self.aggregate.range == result.range,
        self.aggregate.selectedOrigin == result.selectedOrigin, self.aggregate.selectedModel == result.selectedModel {
        self.aggregate.error = result.error
        self.aggregate.coverageReasons = result.coverageReasons
      } else { self.aggregate = result }
    }
  }
  func checkNotificationStatus() {
    guard !isPreview, let notificationClient else {
      notificationStatus = isPreview ? "合成预览：未请求系统许可" : "未打包运行，未访问通知服务"; return
    }
    notificationClient.settings { status in
      Task { @MainActor in
        self.notificationsAuthorized = [.authorized, .provisional, .ephemeral].contains(status)
        switch status {
        case .authorized, .provisional, .ephemeral: self.notificationStatus = "系统通知已授权；发送失败仍保留原入口兜底"
        case .denied: self.notificationStatus = "系统通知已拒绝；Pi原通知和自动化不受影响"
        case .notDetermined: self.notificationStatus = "系统通知尚未授权；点击开启后才申请许可"
        case .unknown: self.notificationStatus = "系统通知许可状态未知；Pi原通知和自动化不受影响"
        }
      }
    }
  }
  func enableNotifications() {
    guard !isPreview, let notificationClient, !requestingNotifications else { return }
    requestingNotifications = true
    notificationStatus = "正在请求系统通知许可…"
    notificationClient.requestAuthorization { result in
      Task { @MainActor in
        self.requestingNotifications = false
        switch result {
        case .success(true):
          self.settings.notifications = true
          self.saveSettings()
          self.checkNotificationStatus()
        case .success(false): self.notificationStatus = "系统通知未获授权；如需启用，请在系统设置中修改Pi Desk通知权限。原Pi通知与自动化不受影响"
        case .failure: self.notificationStatus = "开启系统通知失败；请稍后重试。Pi原通知和自动化不受影响"
        }
      }
    }
  }
  func sendTestNotification() {
    guard !isPreview, notificationsAuthorized, let notificationClient else { return }
    notificationClient.post(id: "pi-desk-synthetic-test-" + UUID().uuidString, title: "Pi Desk 测试通知", body: "这是一条合成测试通知，不会触发Pi模型、工具或原问题操作。") { [weak self] error in
      Task { @MainActor in self?.notificationStatus = error == nil ? "测试通知已由系统受理；不等于横幅已显示，请以实际可见结果为准" : "测试通知发送失败；原Pi执行和通知兜底不变" }
    }
  }
  func sendNotification(for input: InputNotice, session: Identity) {
    guard !isPreview, let notificationClient else { return }
    let key = session.runtimeEpoch + ":" + input.id
    notificationClient.settings { status in
      guard [.authorized, .provisional, .ephemeral].contains(status) else {
        Task { @MainActor in self.checkNotificationStatus() }
        return
      }
      notificationClient.post(id: key, title: "Pi 需要输入", body: "请回到原会话处理。原通知与自动化保持不变。") { error in
        if error != nil { Task { @MainActor in self.notificationStatus = "系统通知发送失败；原入口兜底不受影响" } }
      }
    }
  }
  var connectedCount: Int { sessions.filter { $0.connection == .connected }.count }
  var activeCount: Int { sessions.filter { Presentation.isExecutionActive($0) }.count }
  var unknownExecutionCount: Int { sessions.filter { Presentation.needsExecutionReview($0) }.count }
  var inputCount: Int { sessions.filter { Presentation.needsInput($0) }.count }
  init(notificationClient: NotificationClient? = nil, usageLedger: UsageLedgerClient? = nil) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let args = CommandLine.arguments
    func argument(_ key: String) -> String? {
      guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
      return args[i + 1]
    }
    socketPath =
      argument("--socket-path") ?? ProcessInfo.processInfo.environment["PI_DESK_SOCKET"]
      ?? home.appendingPathComponent("Library/Caches/PiDesk/runtime/desk.sock").path
    settingsURL = URL(
      fileURLWithPath: argument("--settings-path") ?? ProcessInfo.processInfo.environment[
        "PI_DESK_SETTINGS"]
        ?? home.appendingPathComponent("Library/Application Support/PiDesk/settings.json").path)
    let fixturePath = argument("--visual-fixture")
    isPreview = fixturePath != nil
    self.notificationClient = notificationClient ?? (!isPreview && Bundle.main.bundleURL.pathExtension == "app" ? SystemNotificationClient() : nil)
    if let fixturePath = fixturePath {
      diagnostic = "合成视觉预览 · 不连接真实会话"
      do {
        let data = try PrivateSettings.load(URL(fileURLWithPath: fixturePath))
        let preview = try JSONDecoder().decode(VisualFixture.self, from: data)
        guard preview.synthetic, preview.records.count <= 12 else { throw WireError.invalidRecord }
        for record in preview.records {
          try record.validate()
          let connection = UUID()
          let now = Date().timeIntervalSince1970 * 1000
          _ = store.apply(
            record, connection: connection,
            now: preview.connections?[record.identity.nativeSessionId] == "stale"
              ? now - 20000 : now)
          if preview.connections?[record.identity.nativeSessionId] == "disconnected" {
            store.disconnect(connection)
          }
        }
        if args.contains("--large-list-preview"), let first = preview.records.first, let base = first.snapshot {
          for index in 1..<64 {
            var snap = base
            snap.identity.nativeSessionId = "synthetic-list-\(index)"
            snap.identity.runtimeEpoch = "synthetic-epoch-\(index)"
            snap.display.name = "合成项目 \(index) · 长会话名称的搜索与键盘导航检查"
            _ = store.apply(WireRecord(kind: "hello", identity: snap.identity, snapshot: snap), connection: UUID(), now: Date().timeIntervalSince1970 * 1000)
          }
        }
        store.tick(now: Date().timeIntervalSince1970 * 1000)
        selected = sessions.first?.snapshot.identity.sessionKey
        if let previewPage = argument("--visual-page"), ["会话", "Token", "设置"].contains(previewPage) { page = previewPage }
        if page == "Token" {
          refreshUsage()
          if args.contains("--invalid-custom-preview") {
            usagePreset = .custom
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
            usageCustomEnd = calendar.startOfDay(for: Date())
            usageCustomStart = calendar.date(byAdding: .day, value: 1, to: usageCustomEnd)!
            refreshUsage()
          }
        }
      } catch { diagnostic = "合成预览文件不可用；未连接真实会话" }
      return
    }
    loadSettings()
    let usageRoot = argument("--usage-path").map { URL(fileURLWithPath: $0) } ?? (argument("--socket-path").map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("usage-v1") })
    ledger = usageLedger ?? UsageLedger(root: usageRoot)
    ledger?.loadViewState { [weak self] state, issue in
      Task { @MainActor in
        guard let self else { return }
        if let issue { self.actionNote = issue }
        if !self.viewStateTouchedBeforeLoad { self.applyViewState(state) }
        self.viewStateLoaded = true
        self.selectPreferredSession()
        self.refreshUsage()
        if self.viewStateTouchedBeforeLoad { self.persistViewState() }
      }
    }
    refreshUsage(); checkNotificationStatus()
    server = SocketServer(path: socketPath) { [weak self] event in
      if Thread.isMainThread {
        MainActor.assumeIsolated { self?.consume(event) }
      } else {
        Task { @MainActor in self?.consume(event) }
      }
    }
    server.start()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self = self else { return }
        self.store.tick(now: Date().timeIntervalSince1970 * 1000)
        self.refreshUsageIfDue()
      }
    }
  }
  private func consume(_ event: SocketServer.Event) {
    switch event {
    case .record(let record, let connection):
      guard store.apply(record, connection: connection, now: Date().timeIntervalSince1970 * 1000)
      else {
        if record.kind == "hello" { server.close(connection) }
        return
      }
      peerRoutes = peerRoutes.filter { $0.key.sessionKey != record.identity.sessionKey || $0.key == record.identity }
      routeNotes = routeNotes.filter { $0.key.sessionKey != record.identity.sessionKey || $0.key == record.identity }
      if let session = store.sessions[record.identity.sessionKey] { resolveOriginalRoute(session) }
      restoreHidden(record.identity, connection: store.sessions[record.identity.sessionKey]?.connection ?? .connected)
      selectPreferredSession()
      notify()
    case .disconnected(let id):
      peerRoutes = peerRoutes.filter { $0.value.connection != id }
      routeAttempts.removeValue(forKey: id)
      for session in sessions where session.connectionId == id { routeNotes[session.snapshot.identity] = "会话已断开；当前连接定位已失效" }
      store.disconnect(id)
      for session in sessions where session.connectionId == id { restoreHidden(session.snapshot.identity, connection: session.connection) }
      selectPreferredSession()
    case .diagnostic(let code): diagnostic = code == "socket-ready" ? "本机连接已就绪" : "连接不可用：" + code
    }
  }
  func stop() {
    flushViewState()
    timer?.invalidate()
    server?.stop()
  }
  func refresh(usage: Bool = false, identity: Identity? = nil, runId: String? = nil) {
    guard !isPreview, let s = identity.flatMap({ store.sessions[$0.sessionKey] }) ?? current,
      s.connection == .connected, identity == nil || s.snapshot.identity == identity
    else { return }
    let key = s.snapshot.identity.runtimeEpoch + (usage ? ":cost" : ":status") + (runId ?? "")
    let now = Date()
    guard now.timeIntervalSince(ownerQueryTimes[key] ?? .distantPast) >= (usage ? 5 : 2) else { return }
    if ownerQueryTimes.count >= 128 { ownerQueryTimes.removeAll(keepingCapacity: true) }
    ownerQueryTimes[key] = now
    sectionRefreshRequestedAt[s.snapshot.identity] = now
    if sectionRefreshRequestedAt.count > 64 { sectionRefreshRequestedAt = [s.snapshot.identity: now] }
    server.send(
      WireRecord(
        kind: "query", identity: s.snapshot.identity, requestId: UUID().uuidString,
        target: runId.map { Target(owner: "subagents", runId: $0) },
        query: usage ? "usage.refresh" : "refresh"), to: s.connectionId)
  }
  @discardableResult
  func action(
    _ action: Action, target: Target, parameters: Parameters = Parameters(),
    identity: Identity? = nil
  ) -> Bool {
    guard !isPreview else {
      actionNote = "合成预览：未递送任何真实请求"
      return false
    }
    guard let s = identity.flatMap({ store.sessions[$0.sessionKey] }) ?? current,
      identity == nil || s.snapshot.identity == identity,
      let record = store.request(
        identity: s.snapshot.identity, action: action, target: target, parameters: parameters,
        now: Date().timeIntervalSince1970 * 1000)
    else {
      actionNote = "目标不可用，或已有相同操作等待回执；草稿已保留"
      return false
    }
    do {
      _ = try Wire.encode(record)
      server.send(record, to: s.connectionId)
      actionNote = "已发出请求；受理与实际结果分别显示"
      return true
    } catch {
      store.failSend(record.requestId!)
      actionNote = "请求未确认，未自动重发；草稿已保留"
      return false
    }
  }
  func canOpenOriginal(identity: Identity) -> Bool {
    guard let session = store.sessions[identity.sessionKey], session.snapshot.identity == identity, session.connection == .connected,
      let route = session.snapshot.display.route, route.sessionId == identity.nativeSessionId else { return false }
    if route.kind == "terminal" { return route.ttyPath != nil && (route.terminalApp == nil || route.terminalApp == "com.apple.Terminal") }
    return route.kind == "herdr" && route.sessionFile != nil && !settings.herdrExecutable.isEmpty
  }
  func originalRouteLabel(identity: Identity) -> String {
    guard let route = store.sessions[identity.sessionKey]?.snapshot.display.route else { return "原会话不可定位" }
    return route.kind == "terminal" ? "回到原终端" : "打开原会话"
  }
  func openOriginal(identity: Identity? = nil) {
    guard !isPreview else { actionNote = "合成预览：不会切换到其他应用"; return }
    guard let s = identity.flatMap({ store.sessions[$0.sessionKey] }) ?? current,
      identity == nil || s.snapshot.identity == identity, s.connection == .connected,
      let route = s.snapshot.display.route, route.sessionId == s.snapshot.identity.nativeSessionId
    else { actionNote = "没有精确的当前终端/Herdr路由；未打开同名对象或第二个Pi"; return }
    let currentIdentity = s.snapshot.identity
    if route.kind == "terminal" {
      guard (route.terminalApp == nil || route.terminalApp == "com.apple.Terminal"), let ttyPath = route.ttyPath, TerminalRouteActivator.acceptsTTY(ttyPath, terminalRunning: TerminalRouteActivator.isTerminalRunning()) else {
        actionNote = "当前会话没有可验证的Terminal.app TTY路由；不会打开新终端或恢复第二个Pi"
        return
      }
      Task {
        do {
          guard let current = store.sessions[currentIdentity.sessionKey], current.snapshot.identity == currentIdentity, current.connectionId == s.connectionId, current.connection == .connected else { throw NavigationError.unavailable }
          if let binding = peerRoutes[currentIdentity] {
            let info: PeerProcessInfo? = await withCheckedContinuation { continuation in server.peerProcessInfo(s.connectionId) { continuation.resume(returning: $0) } }
            guard let info, info == binding.process else { throw NavigationError.unavailable }
          }
          // Read-only preflight and actual send now share this App actor and
          // exact Terminal PID targets. It still is not a focus success proof.
          let permission = await TerminalRouteActivator.permissionStatus()
          guard permission == "终端Automation已授权" else {
            routeNotes[currentIdentity] = permission
            actionNote = "未发起终端定位：" + permission
            return
          }
          guard let current = store.sessions[currentIdentity.sessionKey], current.snapshot.identity == currentIdentity, current.connectionId == s.connectionId, current.connection == .connected else { throw NavigationError.unavailable }
          let result = try await TerminalRouteActivator.focus(ttyPath: ttyPath)
          guard let current = store.sessions[currentIdentity.sessionKey], current.snapshot.identity == currentIdentity, current.connectionId == s.connectionId, current.connection == .connected else { throw NavigationError.unavailable }
          routeNotes[currentIdentity] = "Pi Desk同进程AppleEvent已唯一匹配并回读：" + result
          actionNote = "已定位准确Terminal tab（\(result)）；未启动新的Pi writer"
        } catch {
          let reason = error is NavigationError ? "当前连接/代际/peer已变化；未宣称旧路由定位成功" : TerminalRouteActivator.diagnostic(error)
          routeNotes[currentIdentity] = reason
          actionNote = "无法定位准确Terminal tab：" + reason + "；不会自动执行pi --session"
        }
      }
      return
    }
    guard route.kind == "herdr", let file = route.sessionFile, !settings.herdrExecutable.isEmpty else {
      actionNote = "没有可用的精确Herdr/Terminal路由；不会打开同名对象或恢复第二个Pi"
      return
    }
    let executable = settings.herdrExecutable
    Task {
      do {
        let raw = try await FiniteCommand.run(executable, ["api", "snapshot"])
        let pane = try Navigation.exactPane(snapshot: raw, sessionFile: file)
        guard store.sessions[currentIdentity.sessionKey]?.snapshot.identity == currentIdentity else { throw NavigationError.unavailable }
        _ = try await FiniteCommand.run(executable, ["agent", "focus", pane.paneId])
        let verify = try await FiniteCommand.run(executable, ["api", "snapshot"])
        let verified = try Navigation.exactPane(snapshot: verify, sessionFile: file)
        guard verified == pane else { throw NavigationError.unavailable }
        actionNote = "原 owner 已处理准确会话的聚焦请求"
      } catch { actionNote = "原会话跳转失败或身份已改变；未选择其他窗口" }
    }
  }
  func openManagement() {
    guard !isPreview else { return }
    guard let url = LinkPolicy.exactHTTPS(settings.managementURL) else {
      actionNote = "管理页未配置或不是无凭据的精确 HTTPS 地址"
      return
    }
    if !NSWorkspace.shared.open(url) { actionNote = "管理页未能打开" }
  }
  func saveSettings() {
    guard !isPreview else {
      actionNote = "合成预览不保存真实设置"
      return
    }
    guard settings.herdrExecutable.isEmpty || settings.herdrExecutable.hasPrefix("/") else {
      actionNote = "Herdr 需为明确的本机绝对可执行路径"
      return
    }
    guard settings.managementURL.isEmpty || LinkPolicy.exactHTTPS(settings.managementURL) != nil
    else {
      actionNote = "管理页仅接受无凭据的精确 HTTPS 地址"
      return
    }
    do {
      try PrivateSettings.save(JSONEncoder().encode(settings), to: settingsURL)
      actionNote = "仅保存本 App 设置，原 Pi 资源与规则未变"
    } catch { actionNote = "本地设置保存失败" }
  }
  private func loadSettings() {
    if let data = try? PrivateSettings.load(settingsURL),
      let value = try? JSONDecoder().decode(DeskSettings.self, from: data)
    {
      settings = value
    }
  }
  func markRead(_ input: InputNotice, session: Identity) {
    if dismissed.count >= 1024 { dismissed.removeAll() }
    dismissed.insert(session.runtimeEpoch + ":" + input.id)
    persistViewState()
  }
  func isRead(_ input: InputNotice, session: Identity) -> Bool {
    let key = session.runtimeEpoch + ":" + input.id
    return dismissed.contains(key) || pendingDismissedHashes.contains(UsageViewStateKey.hash(key))
  }
  private func notify() {
    guard !muted else { return }
    for s in sessions where s.connection == .connected {
      for input in s.snapshot.inputs {
        let key = s.snapshot.identity.runtimeEpoch + ":" + input.id
        guard !notified.contains(key) else { continue }
        if notified.count >= 1024 { notified.removeAll() }
        notified.insert(key)
        guard settings.notifications else { continue }
        sendNotification(for: input, session: s.snapshot.identity)
      }
    }
  }
}

enum FiniteCommand {
  static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let runner = FiniteCommandRunner(
        executable: executable, arguments: arguments, continuation: continuation)
      runner.start()
    }
  }
}
private final class FiniteCommandRunner: @unchecked Sendable {
  private let queue = DispatchQueue(label: "pi-desk.owner-command", qos: .utility)
  private let process = Process()
  private let pipe = Pipe()
  private let executable: String
  private let arguments: [String]
  private var continuation: CheckedContinuation<Data, Error>?
  private var source: DispatchSourceRead?
  private var output = Data()
  private var finished = false
  init(executable: String, arguments: [String], continuation: CheckedContinuation<Data, Error>) {
    self.executable = executable
    self.arguments = arguments
    self.continuation = continuation
  }
  func start() {
    queue.async { [self] in
      do {
        let file = URL(fileURLWithPath: executable)
        let props = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard executable.hasPrefix("/"), props.isRegularFile == true, props.isSymbolicLink != true
        else { throw NavigationError.unavailable }
        process.executableURL = file
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [self] p in
          queue.async { [self] in
            drain()
            finish(p.terminationStatus == 0 ? nil : NavigationError.unavailable)
          }
        }
        try process.run()
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw NavigationError.unavailable }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [self] in drain() }
        source.resume()
        queue.asyncAfter(deadline: .now() + 3) { [self] in
          guard !finished else { return }
          if process.isRunning { process.terminate() }
          queue.asyncAfter(deadline: .now() + 0.25) { [self] in
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            finish(NavigationError.unavailable)
          }
        }
      } catch { finish(error) }
    }
  }
  private func drain() {
    guard !finished else { return }
    var buffer = [UInt8](repeating: 0, count: 8192)
    for _ in 0..<128 {
      let n = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
      if n <= 0 { return }
      guard output.count + n <= 1_048_576 else {
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        finish(NavigationError.invalidResponse)
        return
      }
      output.append(contentsOf: buffer.prefix(n))
    }
  }
  private func finish(_ error: Error?) {
    guard !finished else { return }
    finished = true
    if error != nil && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    source?.cancel()
    source = nil
    process.terminationHandler = nil
    try? pipe.fileHandleForReading.close()
    let callback = continuation
    continuation = nil
    if let error = error {
      callback?.resume(throwing: error)
    } else {
      callback?.resume(returning: output)
    }
  }
}
