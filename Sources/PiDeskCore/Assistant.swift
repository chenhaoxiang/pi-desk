import Foundation

public struct AssistantTextMessage: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var role: String
  public var text: String
  public init(id: String, role: String, text: String) { self.id = id; self.role = role; self.text = text }
  public var valid: Bool { !id.isEmpty && id.utf8.count <= 128 && ["user", "assistant"].contains(role) && text.utf8.count <= 2048 }
}
public struct AssistantModelOption: Codable, Identifiable, Equatable, Sendable {
  public var provider: String
  public var modelId: String
  public var name: String
  public var thinkingLevels: [String]
  public var id: String { provider + "/" + modelId }
  public init(provider: String, modelId: String, name: String, thinkingLevels: [String]) {
    self.provider = provider; self.modelId = modelId; self.name = name; self.thinkingLevels = thinkingLevels
  }
}
public struct AssistantSource: Codable, Equatable, Sendable {
  public var ref: String
  public var title: String
  public var project: String
  public var status: String
  public var tools: [String]
  public var messages: [AssistantTextMessage]
  public init(ref: String, title: String, project: String, status: String, tools: [String], messages: [AssistantTextMessage] = []) {
    self.ref = ref; self.title = title; self.project = project; self.status = status; self.tools = tools; self.messages = messages
  }
}
public struct AssistantSummary: Codable, Identifiable, Equatable, Sendable {
  public var ref: String
  public var text: String
  public var id: String { ref }
}
public struct AssistantGroup: Codable, Identifiable, Equatable, Sendable {
  public var name: String
  public var refs: [String]
  public var reason: String
  public var id: String { name }
}
public struct AssistantAnalysis: Codable, Equatable, Sendable {
  public var overview: String
  public var summaries: [AssistantSummary]
  public var groups: [AssistantGroup]
  public func valid(for refs: Set<String>) -> Bool {
    let seen = summaries.map(\.ref), grouped = groups.flatMap(\.refs)
    return !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && overview.utf8.count <= 4096 && summaries.count <= 8 && Set(seen) == refs && Set(seen).count == seen.count
      && seen.allSatisfy { $0.range(of: "^[A-Za-z0-9._-]{1,16}$", options: .regularExpression) != nil }
      && summaries.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= 4096 }
      && groups.count <= 16 && Set(groups.map(\.name)).count == groups.count
      && Set(grouped).count == grouped.count && Set(grouped).isSubset(of: refs)
      && groups.allSatisfy { !$0.name.isEmpty && $0.name.utf8.count <= 64 && !$0.refs.isEmpty && $0.refs.count <= 8 && $0.reason.utf8.count <= 1024 && !["未分组", "全部分组", "__none__"].contains($0.name) && !$0.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }
  }
}
public struct AssistantUsage: Codable, Equatable, Sendable {
  public var input: Int64
  public var output: Int64
  public var cacheRead: Int64
  public var cacheWrite: Int64
  public var valid: Bool { [input, output, cacheRead, cacheWrite].allSatisfy { $0 >= 0 && $0 <= 9_007_199_254_740_991 } }
}
public struct AssistantPayload: Codable, Sendable {
  public var operation: String
  public var status: String?
  public var code: String?
  public var provider: String?
  public var modelId: String?
  public var thinking: String?
  public var cancelID: String?
  public var models: [AssistantModelOption]?
  public var messages: [AssistantTextMessage]?
  public var revision: String?
  public var partial: Bool?
  public var sources: [AssistantSource]?
  public var extra: String?
  public var analysis: AssistantAnalysis?
  public var usage: AssistantUsage?
  public var possibleUsage: Bool?
  public init(operation: String) { self.operation = operation }
  public var valid: Bool {
    let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    guard ["models", "context", "analyze", "cancel"].contains(operation), status == nil || ["ok", "pending", "error", "unknown", "cancelled"].contains(status!) else { return false }
    guard (code?.utf8.count ?? 0) <= 128, (provider?.utf8.count ?? 0) <= 128, (modelId?.utf8.count ?? 0) <= 128,
      thinking == nil || levels.contains(thinking!), (cancelID?.utf8.count ?? 0) <= 128,
      (extra?.utf8.count ?? 0) <= 4096, (revision?.utf8.count ?? 0) <= 128 else { return false }
    guard (models?.count ?? 0) <= 128, (models ?? []).allSatisfy({ m in
      !m.provider.isEmpty && m.provider.utf8.count <= 128 && !m.modelId.isEmpty && m.modelId.utf8.count <= 128 && m.name.utf8.count <= 64 && !m.thinkingLevels.isEmpty && m.thinkingLevels.count <= 7 && m.thinkingLevels.allSatisfy(levels.contains)
    }) else { return false }
    guard (messages?.count ?? 0) <= 8, (messages ?? []).allSatisfy(\.valid), (sources?.count ?? 0) <= 8 else { return false }
    for source in sources ?? [] {
      guard source.ref.range(of: "^[A-Za-z0-9._-]{1,16}$", options: .regularExpression) != nil, source.title.utf8.count <= 128, source.project.utf8.count <= 128, source.status.utf8.count <= 128,
        source.tools.count <= 3, source.tools.allSatisfy({ $0.utf8.count <= 128 }), source.messages.count <= 8, source.messages.allSatisfy(\.valid) else { return false }
    }
    guard usage == nil || usage!.valid, analysis == nil || analysis!.valid(for: Set(analysis!.summaries.map(\.ref))) else { return false }
    return true
  }
}
