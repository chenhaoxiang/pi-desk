import Foundation
import PiDeskCore

@main enum CoreChecks {
  static func main() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/wire-v1.json"))
    let record = try Wire.decode(data)
    precondition(record.identity.nativeSessionId == "session-a")
    precondition(record.snapshot?.usage.first?.tokens.total == 155)
    precondition(record.snapshot?.execution == .running)
    _ = try Wire.decode(Data(try Wire.encode(record).dropLast()))
    for invalid in [
      Data("{}".utf8), Data(repeating: 32, count: 65_537),
      Data(
        String(data: data, encoding: .utf8)!.replacingOccurrences(
          of: "\"version\": 1", with: "\"version\": 9"
        ).utf8),
    ] {
      do {
        _ = try Wire.decode(invalid)
        fatalError("Expected invalid record rejection")
      } catch {}
    }
    try StateChecks.run(record.snapshot!)
    print(
      "Core checks passed: shared wire, invalid/version/limits, identity, state, usage, requests.")
  }
}
