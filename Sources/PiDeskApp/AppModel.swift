import AppKit
import Darwin
import Foundation
import PiDeskCore
import PiDeskTransport
import SwiftUI
import UserNotifications

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
  private var notified: Set<String> = []
  private var server: SocketServer!
  private var timer: Timer?
  private let settingsURL: URL
  let socketPath: String
  var sessions: [SessionView] {
    store.sessions.values.sorted { $0.snapshot.display.name < $1.snapshot.display.name }
  }
  var current: SessionView? { selected.flatMap { store.sessions[$0] } }
  var activeCount: Int {
    sessions.filter {
      $0.connection == .connected
        && [.running, .retrying, .compacting, .waitingChildren].contains($0.snapshot.execution)
    }.count
  }
  var inputCount: Int {
    sessions.filter { $0.connection == .connected }.reduce(0) { $0 + $1.snapshot.inputs.count }
  }
  init() {
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
    loadSettings()
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
    server.stop()
  }
  func refresh(usage: Bool = false) {
    guard let s = current, s.connection == .connected else { return }
    server.send(
      WireRecord(
        kind: "query", identity: s.snapshot.identity, requestId: UUID().uuidString,
        query: usage ? "usage.refresh" : "refresh"), to: s.connectionId)
  }
  func action(_ action: Action, target: Target, parameters: Parameters = Parameters()) {
    guard let s = current,
      let record = store.request(
        identity: s.snapshot.identity, action: action, target: target, parameters: parameters,
        now: Date().timeIntervalSince1970 * 1000)
    else {
      actionNote = "目标不可用，或已有相同操作等待回执"
      return
    }
    do {
      _ = try Wire.encode(record)
      server.send(record, to: s.connectionId)
      actionNote = "已发出请求；受理与实际结果分别显示"
    } catch {
      store.failSend(record.requestId!)
      actionNote = "请求未确认，未自动重发"
    }
  }
  func openOriginal() {
    guard let s = current, s.connection == .connected, let route = s.snapshot.display.route,
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
        guard current?.snapshot.identity == identity else { throw NavigationError.unavailable }
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
    guard let url = LinkPolicy.exactHTTPS(settings.managementURL) else {
      actionNote = "管理页未配置或不是无凭据的精确 HTTPS 地址"
      return
    }
    if !NSWorkspace.shared.open(url) { actionNote = "管理页未能打开" }
  }
  func saveSettings() {
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
        guard settings.notifications, Bundle.main.bundleURL.pathExtension == "app" else { continue }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { permission in
          guard permission.authorizationStatus == .authorized else { return }
          let content = UNMutableNotificationContent()
          content.title = "Pi 需要输入"
          content.body = "请回到原会话处理。原通知与自动化保持不变。"
          let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
          UNUserNotificationCenter.current().add(request) {
            _ in /* Failure is display-only; never suppress the producer. */
          }
        }
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
