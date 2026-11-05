import Foundation

public enum QuestionWorkPresentation {
  public static func linkedInputs(_ inputs: [InputNotice]) -> [InputNotice] {
    inputs.filter { $0.kind == "question" && $0.question != nil }
  }
}

/// A read-only link reported by the original question owner. It does not expose
/// the prompt/answer or offer a second way to resolve the original question.
public struct QuestionWorkLink: Codable, Equatable, Sendable {
  private static let knownCredential = try! NSRegularExpression(pattern: #"(?i)(?:github_pat_[A-Za-z0-9_]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|sk-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#)
  private func sensitive(_ value: String) -> Bool {
    Self.knownCredential.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil || AssistantPrivacy.sensitive(value)
  }
  public var version: Int
  public var binding: String
  public var workRef: PiWorkRef?
  public var workPhase: String?
  public var ownerEpoch: String
  public var sequence: Int
  public var observedAt: Double
  private func token(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 128 && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
  }
  public var valid: Bool {
    guard version == 1, ["declared", "unbound", "unavailable"].contains(binding), token(ownerEpoch), !sensitive(ownerEpoch), (0...9_007_199_254_740_991).contains(sequence), observedAt.isFinite, observedAt >= 0, observedAt <= 7_258_118_400_000, observedAt.rounded(.towardZero) == observedAt else { return false }
    if binding == "declared" {
      guard let ref = workRef, ref.valid, !sensitive(ref.owner), !sensitive(ref.key) else { return false }
      return workPhase == nil || (token(workPhase!) && !sensitive(workPhase!))
    }
    return workRef == nil && workPhase == nil
  }
  public var title: String {
    guard binding == "declared", let workRef else { return binding == "unbound" ? "原问题未绑定工作" : "原问题工作关联不可用" }
    return workRef.kindTitle + " · " + workRef.key
  }
}
