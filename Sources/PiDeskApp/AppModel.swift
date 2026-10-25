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
  @Published var sessionFilter = "在线"
  @Published var hiddenSessions: Set<String> = []
  @Published var usagePreset: UsagePreset = .today
  @Published var usageMetric: UsageMetric = .interaction
  @Published var usageCustomStart = Date()
  @Published var usageCustomEnd = Date()
  @Published var aggregate = UsageAggregate.empty(.make(preset: .today))
  @Published var usageLoading = false
  @Published var notificationStatus = "尚未检查系统通知状态"
  @Published var requestingNotifications = false
  private let notificationClient: NotificationClient?
  private var ledger: UsageLedgerClient?
  private var lastUsageRefresh = Date.distantPast
  let isPreview: Bool
  var showManager: () -> Void = {}
  var showIsland: () -> Void = {}
  func setDraft(_ value: String, for identity: Identity) {
    if drafts.count >= 64 && drafts[identity] == nil {
      drafts.removeValue(forKey: drafts.keys.first!)
    }
    drafts[identity] = value
  }
  func select(_ identity: Identity) {
    guard store.sessions[identity.sessionKey]?.snapshot.identity == identity else { return }
    if !visibleSessions.contains(where: { $0.snapshot.identity == identity }) {
      search = ""
      sessionFilter = "全部"
      hiddenSessions.remove(identity.sessionKey)
    }
    selected = identity.sessionKey
  }
  private var notified: Set<String> = []
  private var server: SocketServer!
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
      let matchesState = sessionFilter == "在线" ? s.connection == .connected : sessionFilter == "全部" || (sessionFilter == "运行中" && s.connection == .connected && [.running, .waitingChildren, .retrying, .compacting].contains(snap.execution)) || (sessionFilter == "需输入" && !snap.inputs.isEmpty) || (sessionFilter == "断连" && s.connection != .connected)
      return matchesSearch && matchesState && (!hiddenSessions.contains(snap.identity.sessionKey) || s.connection == .connected)
    }
  }
  func hideDisconnected(_ identity: Identity) {
    guard let s = store.sessions[identity.sessionKey], s.snapshot.identity == identity, s.connection != .connected else { return }
    hiddenSessions.insert(identity.sessionKey)
    if selected == identity.sessionKey { selected = visibleSessions.first?.snapshot.identity.sessionKey }
    actionNote = "仅隐藏断连卡片，未停止或删除任何Pi工作"
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
    if isPreview { aggregate = .empty(range, preview: true); return }
    guard !usageLoading, let ledger else { return }
    usageLoading = true; lastUsageRefresh = Date()
    ledger.refresh(range: range) { [weak self] result in
      guard let self else { return }
      self.usageLoading = false
      guard self.customRangeIsValid else { return }
      let expected = UsageDateRange.make(preset: self.usagePreset, customStart: self.usageCustomStart, customEnd: self.usageCustomEnd)
      guard expected == result.range else { self.refreshUsage(); return }
      if result.error != nil, self.aggregate.totals.seen, self.aggregate.range == result.range {
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
  var activeCount: Int {
    sessions.filter {
      $0.connection == .connected && $0.snapshot.inputs.isEmpty
        && [.running, .retrying, .compacting, .waitingChildren].contains($0.snapshot.execution)
    }.count
  }
  var inputCount: Int {
    sessions.filter { $0.connection == .connected }.reduce(0) { $0 + $1.snapshot.inputs.count }
  }
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
        if Date().timeIntervalSince(self.lastUsageRefresh) >= (self.page == "Token" ? 5 : 30) { self.refreshUsage() }
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
      if selected == nil { selected = record.identity.sessionKey }
      notify()
    case .disconnected(let id): store.disconnect(id)
    case .diagnostic(let code): diagnostic = code == "socket-ready" ? "本机连接已就绪" : "连接不可用：" + code
    }
  }
  func stop() {
    timer?.invalidate()
    server?.stop()
  }
  func refresh(usage: Bool = false, identity: Identity? = nil) {
    guard !isPreview, let s = identity.flatMap({ store.sessions[$0.sessionKey] }) ?? current,
      s.connection == .connected, identity == nil || s.snapshot.identity == identity
    else { return }
    server.send(
      WireRecord(
        kind: "query", identity: s.snapshot.identity, requestId: UUID().uuidString,
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
  func openOriginal(identity: Identity? = nil) {
    guard !isPreview else {
      actionNote = "合成预览：不会切换到其他应用"
      return
    }
    guard let s = identity.flatMap({ store.sessions[$0.sessionKey] }) ?? current,
      identity == nil || s.snapshot.identity == identity, s.connection == .connected,
      let route = s.snapshot.display.route,
      route.kind == "herdr", route.sessionId == s.snapshot.identity.nativeSessionId,
      let file = route.sessionFile, !settings.herdrExecutable.isEmpty
    else {
      actionNote = "没有核实的当前路由；请在原会话操作或配置 Herdr，不会打开同名对象"
      return
    }
    let executable = settings.herdrExecutable
    let identity = s.snapshot.identity
    Task {
      do {
        let raw = try await FiniteCommand.run(executable, ["api", "snapshot"])
        let pane = try Navigation.exactPane(snapshot: raw, sessionFile: file)
        guard store.sessions[identity.sessionKey]?.snapshot.identity == identity else {
          throw NavigationError.unavailable
        }
        // Only this fixed public owner action; never send-keys, shell or lifecycle control.
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
  }
  func isRead(_ input: InputNotice, session: Identity) -> Bool {
    dismissed.contains(session.runtimeEpoch + ":" + input.id)
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
