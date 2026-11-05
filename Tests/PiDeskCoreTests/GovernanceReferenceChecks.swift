import Foundation
import PiDeskCore

enum GovernanceReferenceChecks {
  static func run(_ base: Snapshot, projection: GovernanceProjection) throws {
    let accepted = ["effect:a/1", "CI 41910104247 green", "已有验收引用", String(repeating: "x", count: 256), String(repeating: "😀", count: 128)]
    let rejected = ["", String(repeating: "x", count: 257), String(repeating: "😀", count: 129), "/Users/private", "/home/demo", "C:\\private\\case", "a;b", "a&&b", "a`b", "https://user:pass@example.invalid", "command x", "content note", "fact\u{0085}other", "fact\nother"]
    for (allowed, values) in [(true, accepted), (false, rejected)] {
      for value in values {
        for field in 0..<3 {
          var handoff = projection.handoffs[0].observation
          handoff.acceptedFactRefs = []; handoff.unresolvedEffectRefs = []; handoff.blockerRefs = []
          switch field {
          case 0: handoff.acceptedFactRefs = [value]
          case 1: handoff.unresolvedEffectRefs = [value]
          default: handoff.blockerRefs = [value]
          }
          precondition(handoff.valid == allowed, "handoff reference acceptance/rejection changed")
        }
      }
    }
    var maximal = projection
    maximal.results = []
    maximal.handoffs = [projection.handoffs[0]]
    maximal.handoffs[0].observation.acceptedFactRefs = (0..<64).map { "fact-\($0)" }
    maximal.handoffs[0].observation.unresolvedEffectRefs = (0..<64).map { "effect-\($0)" }
    maximal.handoffs[0].observation.blockerRefs = (0..<64).map { "block-\($0)" }
    let projectionBytes = try JSONEncoder().encode(maximal)
    precondition(projectionBytes.count < 6000)
    var snapshot = base; snapshot.governance = maximal
    let data = Data(try Wire.encode(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot)).dropLast())
    let connection = UUID()
    var samples: [Double] = [], checksum = 0
    for _ in 0..<200 {
      let start = DispatchTime.now().uptimeNanoseconds
      let record = try Wire.decode(data)
      var store = SessionStore()
      precondition(store.apply(record, connection: connection, now: snapshot.observedAt))
      checksum += store.sessions[snapshot.identity.sessionKey]!.snapshot.governance!.handoffs[0].observation.acceptedFactRefs.count
      samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    samples.sort()
    precondition(checksum == 12800)
    let report: [String: Any] = ["synthetic": true, "scenario": "governance-wire-decode-and-store", "references": 192, "iterations": 200, "checksum": checksum, "wireBytes": data.count, "p50ms": samples[100], "p95ms": samples[190], "maxms": samples.last!]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
  }
}
