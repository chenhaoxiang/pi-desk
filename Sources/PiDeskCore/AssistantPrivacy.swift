import Foundation

public enum AssistantDefaults {
  public static let provider = "codex-local-8319"
  public static let model = "gpt-6.1-sol"
  public static let thinking = "medium"
}
public enum AssistantPrivacy {
  private static let patterns = [
    #"(?i)\bauthorization\s*[:=：]\s*["']?(?:bearer|basic)\s+\S{6,}"#,
    #"(?i)(?:password|passwd|密码)\s*[:=：]\s*["']?[^\s"']{4,}"#,
    #"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b"#,
    #"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#,
    #"(?i)(?:authorization|api[-_ ]?key|access[-_ ]?token|password|passwd|secret|密码|密钥|令牌)\s*[:=：]\s*["']?[^\s"']{8,}"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }
  public static func sensitive(_ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return patterns.contains { $0.firstMatch(in: value, range: range) != nil }
  }
  public static func sensitive(sources: [AssistantSource], extra: String) -> Bool {
    sensitive(extra) || sources.contains { source in
      ([source.title, source.project, source.status] + source.tools + source.messages.map(\.text)).contains(where: sensitive)
    }
  }
  public static func bounded(_ value: String, bytes limit: Int) -> String {
    var output = "", count = 0
    for scalar in value.unicodeScalars {
      let char = String(scalar), size = char.utf8.count
      if count + size > limit { break }
      output += char; count += size
    }
    return output
  }
}
