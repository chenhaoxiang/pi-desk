import AppKit
import ApplicationServices
import Foundation

// Only fixed Terminal metadata/get/set/activate events are sent. There is no
// AppleScript source, osascript child, shell command, terminal text or arbitrary AE entry point.
enum TerminalRouteActivator {
  enum Error: Swift.Error, Equatable {
    case unavailable, noMatch, ambiguous, identityMismatch, capacity, timedOut, busy
    case appleEvent(Int32)
    case eventFailure(Int32, String)
  }
  struct TerminalProcess: Equatable {
    let pid: Int32
    let launchedAt: TimeInterval
  }
  struct Tab: Equatable {
    let process: TerminalProcess
    let windowID: Int32
    let index: Int32
    let tty: String
  }
  struct Selection: Equatable {
    let windowID: Int32
    let tty: String
    let frontmost: Bool
  }
  protocol Client {
    func processes() throws -> [TerminalProcess]
    func tabs(in process: TerminalProcess) throws -> [Tab]
    func select(_ tab: Tab) throws
    func selected(in process: TerminalProcess) throws -> Selection
  }
  private static let queue = DispatchQueue(label: "pi-desk.terminal-automation", qos: .utility)
  private static let lock = NSLock()
  private static var locating = false
  static func isTerminalRunning() -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty }
  static func acceptsTTY(_ path: String?, terminalRunning: Bool) -> Bool {
    guard terminalRunning, let path else { return false }
    return path.range(of: "^/dev/(ttys[A-Za-z0-9]+|pts/[0-9]+)$", options: .regularExpression) != nil
  }
  static func permissionStatus(requestConsent: Bool = false) async -> String {
    await withCheckedContinuation { continuation in
      queue.async {
        do {
          let processes = try EventsClient().processes()
          guard !processes.isEmpty else { continuation.resume(returning: "Terminal.app未运行；不会自动启动"); return }
          for process in processes {
            // Same application process and exact PID target as the actual send.
            let target = NSAppleEventDescriptor(processIdentifier: process.pid)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, requestConsent)
            switch status {
            case noErr: continue
            case OSStatus(-1744): continuation.resume(returning: "终端Automation尚未授权；请主动请求权限，由用户决定"); return
            case OSStatus(-1743): continuation.resume(returning: "终端Automation已拒绝；请由用户在系统设置检查权限"); return
            default: continuation.resume(returning: "终端Automation状态不可用（\(status)）；未发起定位"); return
            }
          }
          continuation.resume(returning: "终端Automation已授权")
        } catch { continuation.resume(returning: diagnostic(error)) }
      }
    }
  }
  static func diagnostic(_ error: Swift.Error) -> String {
    guard let error = error as? Error else { return "终端定位内部错误；未宣称定位成功" }
    switch error {
    case .unavailable: return "TTY或Terminal进程实例不可核验；未启动替代Pi"
    case .noMatch: return "所有Terminal实例均无精确TTY匹配（0匹配）；未改变其他窗口"
    case .ambiguous: return "Terminal中出现多个TTY匹配；未选择第一个窗口"
    case .identityMismatch: return "目标TTY/窗口/进程回读不一致；未宣称定位成功"
    case .capacity: return "Terminal实例或tab超出有界核验范围；未按不完整结果聚焦"
    case .timedOut: return "Terminal AppleEvent超时；未宣称定位成功"
    case .busy: return "已有终端定位正在进行；未追加重复操作"
    case .appleEvent(let code):
      if code == -1743 || code == -1744 { return "Pi Desk进程的Terminal AppleEvent未获授权（\(code)）；不等同其他进程权限" }
      return "Pi Desk进程的Terminal AppleEvent失败（\(code)）；未宣称定位成功"
    case .eventFailure(let code, let stage):
      return "Pi Desk进程的Terminal AppleEvent失败（\(code)，阶段：\(stage)）；未宣称定位成功"
    }
  }
  static func focus(ttyPath: String) async throws -> String {
    guard acceptsTTY(ttyPath, terminalRunning: isTerminalRunning()) else { throw Error.unavailable }
    let admitted: Bool = lock.withLock { if locating { return false }; locating = true; return true }
    guard admitted else { throw Error.busy }
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        defer { lock.withLock { locating = false } }
        do { continuation.resume(returning: try locateAndFocus(ttyPath: ttyPath, client: EventsClient())) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
  // Fixture seam exercises the same unique-match/readback algorithm without
  // touching a real Terminal, permission database, or business Pi.
  static func locateAndFocus(ttyPath: String, client: Client) throws -> String {
    guard acceptsTTY(ttyPath, terminalRunning: true) else { throw Error.unavailable }
    let processes = try client.processes()
    guard !processes.isEmpty, processes.count <= 8, Set(processes.map(\.pid)).count == processes.count else { throw Error.capacity }
    var matches: [Tab] = [], total = 0
    for process in processes {
      let tabs = try client.tabs(in: process)
      total += tabs.count
      guard total <= 512, tabs.allSatisfy({ $0.process == process }) else { throw Error.capacity }
      matches += tabs.filter { $0.tty == ttyPath }
    }
    guard !matches.isEmpty else { throw Error.noMatch }
    guard matches.count == 1, let target = matches.first else { throw Error.ambiguous }
    try client.select(target)
    let selected = try client.selected(in: target.process)
    guard selected.frontmost, selected.windowID == target.windowID, selected.tty == ttyPath else { throw Error.identityMismatch }
    return "TTY:\(ttyPath) · Terminal PID:\(target.process.pid) · window:\(target.windowID)"
  }

  // Numeric selectors use Terminal.sdef's stable window ID and the tab's exact
  // TTY, not a bundle-default Terminal instance, window title, cwd or terminal contents.
  final class EventsClient: Client {
    private let deadline = ProcessInfo.processInfo.systemUptime + 12
    private var stage = "枚举Terminal实例"
    private func check(_ process: TerminalProcess) throws {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw Error.timedOut }
      guard let app = NSRunningApplication(processIdentifier: process.pid), !app.isTerminated,
        app.bundleIdentifier == "com.apple.Terminal", app.launchDate?.timeIntervalSince1970 == process.launchedAt
      else { throw Error.identityMismatch }
    }
    func processes() throws -> [TerminalProcess] {
      let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
      guard apps.count <= 8 else { throw Error.capacity }
      return try apps.map { app in
        guard !app.isTerminated, let launchedAt = app.launchDate?.timeIntervalSince1970 else { throw Error.unavailable }
        return TerminalProcess(pid: app.processIdentifier, launchedAt: launchedAt)
      }.sorted { $0.pid < $1.pid }
    }
    func tabs(in process: TerminalProcess) throws -> [Tab] {
      stage = "枚举窗口ID"
      let windows = object("cwin", form: "indx", selector: absoluteOrdinal("all "))
      let ids = try get(property("ID  ", of: windows), in: process)
      guard ids.descriptorType == code("list"), ids.numberOfItems <= 64 else { throw Error.capacity }
      var result: [Tab] = []
      if ids.numberOfItems == 0 { return [] }
      for index in 1...ids.numberOfItems {
        guard let id = ids.atIndex(index), id.descriptorType == code("long") else { throw Error.identityMismatch }
        let windowID = id.int32Value
        let window = windowObject(windowID)
        let tabs = object("ttab", form: "indx", selector: absoluteOrdinal("all "), container: window)
        stage = "读取tab TTY"
        let ttys = try get(property("ttty", of: tabs), in: process)
        guard ttys.descriptorType == code("list"), ttys.numberOfItems <= 128 else { throw Error.capacity }
        if ttys.numberOfItems == 0 { continue }
        for tabIndex in 1...ttys.numberOfItems {
          guard let tty = ttys.atIndex(tabIndex)?.stringValue, tty.utf8.count <= 128 else { throw Error.identityMismatch }
          result.append(Tab(process: process, windowID: windowID, index: Int32(tabIndex), tty: tty))
          guard result.count <= 512 else { throw Error.capacity }
        }
      }
      return result
    }
    func select(_ tab: Tab) throws {
      let window = windowObject(tab.windowID)
      let target = object("ttab", form: "indx", selector: NSAppleEventDescriptor(int32: tab.index), container: window)
      stage = "聚焦前TTY复核"
      guard try get(property("ttty", of: target), in: tab.process).stringValue == tab.tty else { throw Error.identityMismatch }
      stage = "恢复准确窗口"
      let minimized = try get(property("pmnd", of: window), in: tab.process)
      if minimized.booleanValue { try set(property("pmnd", of: window), to: NSAppleEventDescriptor(boolean: false), in: tab.process) }
      stage = "选中准确tab"
      try set(property("tbsl", of: target), to: NSAppleEventDescriptor(boolean: true), in: tab.process)
      stage = "前置准确窗口"
      try set(property("pidx", of: window), to: NSAppleEventDescriptor(int32: 1), in: tab.process)
      stage = "激活准确Terminal实例"
      _ = try send(eventClass: "misc", eventID: "actv", in: tab.process)
    }
    func selected(in process: TerminalProcess) throws -> Selection {
      // Activation can settle asynchronously; bounded utility-thread readback.
      stage = "回读前窗/选中TTY"
      var selection = Selection(windowID: 0, tty: "", frontmost: false)
      for _ in 0..<5 {
        let window = object("cwin", form: "indx", selector: NSAppleEventDescriptor(int32: 1))
        let id = try get(property("ID  ", of: window), in: process)
        let tty = try get(property("ttty", of: property("tcnt", of: window)), in: process)
        let frontmost = try get(property("pisf", of: window), in: process)
        guard let value = tty.stringValue else { throw Error.identityMismatch }
        selection = Selection(windowID: id.int32Value, tty: value, frontmost: frontmost.booleanValue && NSRunningApplication(processIdentifier: process.pid)?.isActive == true)
        if selection.frontmost { return selection }
        Thread.sleep(forTimeInterval: 0.05)
      }
      return selection
    }
    private func get(_ object: NSAppleEventDescriptor, in process: TerminalProcess) throws -> NSAppleEventDescriptor {
      let reply = try send(eventClass: "core", eventID: "getd", direct: object, in: process)
      guard let value = reply.paramDescriptor(forKeyword: code("----")) else { throw Error.identityMismatch }
      return value
    }
    private func set(_ object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, in process: TerminalProcess) throws {
      _ = try send(eventClass: "core", eventID: "setd", direct: object, value: value, in: process)
    }
    private func send(eventClass: String, eventID: String, direct: NSAppleEventDescriptor? = nil, value: NSAppleEventDescriptor? = nil, in process: TerminalProcess) throws -> NSAppleEventDescriptor {
      try check(process)
      let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID), targetDescriptor: NSAppleEventDescriptor(processIdentifier: process.pid), returnID: -1, transactionID: 0)
      if let direct { event.setParam(direct, forKeyword: code("----")) }
      if let value { event.setParam(value, forKeyword: code("data")) }
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { throw Error.timedOut }
      do {
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: min(2, remaining))
        guard reply.data.count <= 65_536 else { throw Error.capacity }
        if let failure = reply.paramDescriptor(forKeyword: code("errn")), failure.int32Value != 0 { throw Error.eventFailure(failure.int32Value, stage) }
        try check(process)
        return reply
      } catch let error as Error { throw error }
      catch {
        let code = Int32((error as NSError).code)
        throw code == -1712 ? Error.timedOut : Error.eventFailure(code, stage)
      }
    }
    private func absoluteOrdinal(_ value: String) -> NSAppleEventDescriptor {
      let ordinal = NSAppleEventDescriptor(enumCode: code(value))
      return NSAppleEventDescriptor(descriptorType: code("abso"), data: ordinal.data)!
    }
    private func windowObject(_ id: Int32) -> NSAppleEventDescriptor {
      object("cwin", form: "ID  ", selector: NSAppleEventDescriptor(int32: id))
    }
    private func property(_ name: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
      object("prop", form: "prop", selector: NSAppleEventDescriptor(typeCode: code(name)), container: container)
    }
    private func object(_ desiredClass: String, form: String, selector: NSAppleEventDescriptor, container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
      let record = NSAppleEventDescriptor.record()
      record.setDescriptor(NSAppleEventDescriptor(typeCode: code(desiredClass)), forKeyword: code("want"))
      record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
      record.setDescriptor(selector, forKeyword: code("seld"))
      record.setDescriptor(container, forKeyword: code("from"))
      return record.coerce(toDescriptorType: code("obj "))!
    }
  }
  private static func code(_ string: String) -> OSType {
    precondition(string.utf8.count == 4)
    return string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
  }
}
