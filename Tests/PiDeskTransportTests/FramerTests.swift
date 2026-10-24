import Foundation
import PiDeskCore
import PiDeskTransport

@main enum TransportChecks {
  static func main() throws {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--serve" {
      SocketHarness.serve(CommandLine.arguments[2])
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let raw = try Data(contentsOf: root.appendingPathComponent("Fixtures/wire-v1.json"))
    let record = try Wire.decode(raw)
    let data = try Wire.encode(record)
    var framer = LineFramer()
    let first = try framer.append(data.prefix(10))
    precondition(first.isEmpty)
    let second = try framer.append(data.dropFirst(10))
    precondition(second.count == 1)
    do {
      _ = try framer.append(Data(repeating: 32, count: 65_537))
      fatalError("Expected oversized frame rejection")
    } catch {}
    print("Transport framing checks passed.")
  }
}
