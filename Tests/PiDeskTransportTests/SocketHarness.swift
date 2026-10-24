import Darwin
import Foundation
import PiDeskCore
import PiDeskTransport

private final class HarnessState: @unchecked Sendable {
  private let lock = NSLock()
  private var connections: [String: (Identity, UUID)] = [:]
  func set(_ identity: Identity, _ id: UUID) {
    lock.lock()
    defer { lock.unlock() }
    connections[identity.nativeSessionId] = (identity, id)
  }
  func get(_ identity: Identity) -> UUID? {
    lock.lock()
    defer { lock.unlock() }
    guard let pair = connections[identity.nativeSessionId], pair.0 == identity else { return nil }
    return pair.1
  }
  func output(_ value: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    if var data = try? JSONSerialization.data(withJSONObject: value) {
      data.append(10)
      FileHandle.standardOutput.write(data)
    }
  }
}
enum SocketHarness {
  static func serve(_ path: String) -> Never {
    let state = HarnessState()
    let server = SocketServer(path: path) { event in
      switch event {
      case .record(let record, let id):
        state.set(record.identity, id)
        if let data = try? JSONEncoder().encode(record),
          let raw = try? JSONSerialization.jsonObject(with: data)
        {
          state.output(["event": "record", "record": raw])
        }
      case .disconnected: state.output(["event": "disconnected"])
      case .diagnostic(let code): state.output(["event": code])
      }
    }
    server.start()
    DispatchQueue.global().async {
      while let line = readLine() {
        do {
          let record = try Wire.decode(Data(line.utf8))
          if let id = state.get(record.identity) { server.send(record, to: id) }
        } catch { state.output(["event": "invalid-test-command"]) }
      }
      server.stop()
      exit(0)
    }
    dispatchMain()
  }
}
