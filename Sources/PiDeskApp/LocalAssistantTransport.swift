import Foundation
import PiDeskCore

@MainActor final class LocalAssistantTransport {
  struct Installation {
    let node: String
    let sdk: String
    let helper: String
    static func discover() -> Installation? {
      let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
      let roots = ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path]
      guard let node = roots.map({ $0 + "/node" }).first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
      let helper = Bundle.main.resourceURL?.appendingPathComponent("bridge/src/local-assistant.ts").path
      guard let helper, fm.fileExists(atPath: helper) else { return nil }
      for root in roots where fm.isExecutableFile(atPath: root + "/pi") {
        let bin = URL(fileURLWithPath: root + "/pi").resolvingSymlinksInPath().deletingLastPathComponent()
        for sdk in [bin.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/index.js"), bin.appendingPathComponent("index.js")] where fm.fileExists(atPath: sdk.path) {
          return Installation(node: node, sdk: sdk.path, helper: helper)
        }
      }
      return nil
    }
  }
  private let installation: Installation?
  private var calls: [String: LocalAssistantCall] = [:]
  init(installation: Installation? = Installation.discover()) { self.installation = installation }
  var available: Bool { installation != nil }
  func stop() { for call in calls.values { call.stop() }; calls.removeAll() }
  @discardableResult func send(_ payload: AssistantPayload, id: String, completion: @escaping (AssistantPayload) -> Void) -> Bool {
    if payload.operation == "cancel", let target = payload.cancelID, let call = calls[target] {
      call.cancel(); var reply = AssistantPayload(operation: "cancel"); reply.status = "ok"; reply.code = "cancel-requested"; completion(reply); return true
    }
    guard let installation, calls.count < 4, ["models", "analyze"].contains(payload.operation) else { return false }
    let call = LocalAssistantCall(installation: installation, payload: payload, id: id, completion: { result in
      Task { @MainActor in completion(result) }
    }, exited: { [weak self] in Task { @MainActor in self?.calls.removeValue(forKey: id) } })
    calls[id] = call; call.start(); return true
  }
}

private final class LocalAssistantCall: @unchecked Sendable {
  private let queue = DispatchQueue(label: "pi-desk.local-assistant", qos: .utility)
  private let writer = DispatchQueue(label: "pi-desk.local-assistant.stdin", qos: .utility)
  private let process = Process(), input = Pipe(), output = Pipe()
  private let installation: LocalAssistantTransport.Installation
  private let payload: AssistantPayload, id: String
  private var data = Data(), finished = false, exited = false
  private let completion: (AssistantPayload) -> Void
  private let onExit: () -> Void
  init(installation: LocalAssistantTransport.Installation, payload: AssistantPayload, id: String, completion: @escaping (AssistantPayload) -> Void, exited: @escaping () -> Void) {
    self.installation = installation; self.payload = payload; self.id = id; self.completion = completion; self.onExit = exited
  }
  func start() {
    queue.async { [self] in
      do {
        process.executableURL = URL(fileURLWithPath: installation.node)
        process.arguments = ["--disable-warning=ExperimentalWarning", installation.helper, installation.sdk]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
          let chunk = handle.availableData
          self?.queue.async { [weak self] in self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] _ in self?.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.didExit() } }
        try process.run()
        struct Packet: Encodable { let id: String; let payload: AssistantPayload }
        var packet = try JSONEncoder().encode(Packet(id: id, payload: payload)); packet.append(10)
        write(packet)
        queue.asyncAfter(deadline: .now() + (payload.operation == "analyze" ? 135 : 20)) { [weak self] in self?.finishUnknown() }
      } catch { finishUnknown(); didExit() }
    }
  }
  func stop() { queue.async { [self] in finishUnknown() } }
  func cancel() {
    queue.async { [self] in
      guard !finished else { return }
      var cancel = AssistantPayload(operation: "cancel"); cancel.cancelID = id
      struct Packet: Encodable { let id: String; let payload: AssistantPayload }
      if var bytes = try? JSONEncoder().encode(Packet(id: "cancel-" + id, payload: cancel)) { bytes.append(10); write(bytes) }
      finishUnknown() // Return promptly; SIGTERM is graceful and SDK auth cleanup remains alive.
    }
  }
  private func write(_ bytes: Data) {
    // Pipe backpressure must never block the state/deadline/termination queue.
    writer.async { [self] in
      do { try input.fileHandleForWriting.write(contentsOf: bytes) }
      catch { queue.async { [self] in finishUnknown() } }
    }
  }
  private func receive(_ chunk: Data) {
    guard !finished else { return }
    data.append(chunk)
    guard data.count <= 65536 else { finishUnknown(); return }
    if let end = data.firstIndex(of: 10) {
      guard let result = try? JSONDecoder().decode(AssistantPayload.self, from: data.prefix(upTo: end)), result.valid, result.operation == payload.operation, result.status != nil else { finishUnknown(); return }
      finish(result)
    }
  }
  private func finishUnknown() {
    guard !finished else { return }
    var result = AssistantPayload(operation: payload.operation)
    result.status = payload.operation == "analyze" ? "unknown" : "error"
    result.code = payload.operation == "analyze" ? "cancel-or-timeout" : "registry-unavailable"
    result.possibleUsage = payload.operation == "analyze"
    finish(result, requestStop: true)
  }
  private func finish(_ result: AssistantPayload, requestStop: Bool = false) {
    guard !finished else { return }; finished = true
    if requestStop && process.isRunning { process.terminate() }
    // Do not kill on a terminal payload. The SDK may still be saving rotated OAuth credentials.
    writer.async { [self] in try? input.fileHandleForWriting.close() }
    completion(result)
  }
  private func didExit() {
    guard !exited else { return }; exited = true
    finishUnknown()
    output.fileHandleForReading.readabilityHandler = nil
    try? output.fileHandleForReading.close()
    onExit()
  }
}
