import CryptoKit
import Foundation

public enum DeskNavigation {
  public static let pages = ["会话", "Token", "重要事项", "AI助手", "接入健康", "设置"]
}

public enum DeskModal: String, Identifiable {
  case commands, drafts, groups
  public var id: String { rawValue }
}
public enum IslandDisplayMode: String, CaseIterable, Identifiable {
  case automatic, menuOnly, pinned
  public var id: String { rawValue }
  public var title: String { switch self { case .automatic: return "自动顶部速览"; case .menuOnly: return "仅菜单栏"; case .pinned: return "默认固定展开" } }
}

public struct DeskCommandEntry: Identifiable {
  public let id: String
  public let title: String
  public let detail: String
  public let action: String
  public let value: String
  public let identity: Identity?
  public init(id: String, title: String, detail: String = "", action: String, value: String = "", identity: Identity? = nil) {
    self.id = id; self.title = title; self.detail = detail; self.action = action; self.value = value; self.identity = identity
  }
  public func matches(_ query: String) -> Bool { query.isEmpty || (title + " " + detail).localizedCaseInsensitiveContains(query) }
}

public struct NotificationTarget: Codable, Equatable, Sendable {
  public var version = 1
  public var sessionHash: String
  public var runtimeHash: String
  public var inputHash: String?
  public static func hash(_ value: String) -> String {
    let digits = Array("0123456789abcdef".utf8)
    let digest = SHA256.hash(data: Data(value.utf8))
    var bytes = [UInt8](); bytes.reserveCapacity(64)
    for byte in digest { bytes.append(digits[Int(byte >> 4)]); bytes.append(digits[Int(byte & 15)]) }
    return String(decoding: bytes, as: UTF8.self)
  }
  public init(identity: Identity, inputID: String? = nil) {
    sessionHash = Self.hash(identity.sessionKey)
    runtimeHash = Self.hash(identity.sessionKey + ":" + identity.runtimeEpoch)
    inputHash = inputID.map { Self.hash(identity.runtimeEpoch + ":" + $0) }
  }
  public var valid: Bool {
    func hash(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
    return version == 1 && hash(sessionHash) && hash(runtimeHash) && (inputHash == nil || hash(inputHash!))
  }
  public func matches(_ identity: Identity) -> Bool {
    valid && sessionHash == Self.hash(identity.sessionKey) && runtimeHash == Self.hash(identity.sessionKey + ":" + identity.runtimeEpoch)
  }
  public func sameSession(_ identity: Identity) -> Bool { valid && sessionHash == Self.hash(identity.sessionKey) }
  public var payload: String? {
    guard valid, let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
  public static func decode(_ value: String) -> NotificationTarget? {
    guard value.utf8.count <= 512, let data = value.data(using: .utf8),
      let target = try? JSONDecoder().decode(Self.self, from: data), target.valid else { return nil }
    return target
  }
}

public struct DeskHealthRow: Identifiable {
  public let id: String
  public let title: String
  public let detail: String
  public let tone: StatusTone
  public init(_ id: String, _ title: String, _ detail: String, tone: StatusTone = .muted) {
    self.id = id; self.title = title; self.detail = detail; self.tone = tone
  }
}
