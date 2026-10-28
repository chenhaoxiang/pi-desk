import Foundation
import PiDeskCore

public struct LineFramer {
  private var buffer = Data()
  public init() {}
  public var bufferedBytes: Int { buffer.count }
  public mutating func append(_ chunk: Data) throws -> [WireRecord] {
    var records: [WireRecord] = []
    // Feed bounded slices; a caller cannot force an unbounded carry buffer.
    for byte in chunk {
      if byte == 10 {
        guard !buffer.isEmpty else { throw WireError.invalidRecord }
        let frame = buffer
        buffer.removeAll(keepingCapacity: true)
        records.append(try Wire.decode(frame))
        guard records.count <= 128 else { throw WireError.oversized }
      } else {
        guard buffer.count < Wire.maximumFrame else { throw WireError.oversized }
        buffer.append(byte)
      }
    }
    return records
  }
}
