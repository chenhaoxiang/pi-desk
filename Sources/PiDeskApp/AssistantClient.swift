import Foundation
import Combine
import PiDeskCore

struct PreparedAssistantSource: Identifiable {
  let identity: Identity
  var source: AssistantSource
  var note: String
  var id: String { source.ref }
}
@MainActor final class DeskAssistantClient: ObservableObject {
  @Published var models: [AssistantModelOption] = []
  @Published var selectedKeys: Set<String> = []
  @Published var prepared: [PreparedAssistantSource] = []
  @Published var extra = ""
  @Published var notice = "按需分析，不改变业务 Pi 的状态或执行。"
  @Published var busy = false
  @Published var loadingModels = false
  @Published var preparing = false
  @Published var analysis: AssistantAnalysis?
  @Published var generatedAt: Date?
  @Published var resultModel = ""
  @Published var resultSources: [PreparedAssistantSource] = []
  private weak var model: AppModel?
  private let transport: ((AssistantPayload, Identity, String) -> Bool)?
  init(transport: ((AssistantPayload, Identity, String) -> Bool)? = nil) { self.transport = transport }
  private var broker: Identity?
  private struct Pending { let identity: Identity; let operation: String; let ref: String?; let deadline: Double }
  private var pending: [String: Pending] = [:]
  private var generation: String?
  private var generationFingerprint = ""
  private var submittedExtra = ""
  var hasUnsentExtra: Bool { !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && extra != submittedExtra }
  private struct CacheInput: Encodable { let request: AssistantPayload; let broker: Identity; let identities: [Identity] }
  private struct Cached { let fingerprint: String; let sources: [PreparedAssistantSource]; let analysis: AssistantAnalysis; let at: Date; let model: String }
  private var cached: Cached?

  func bind(_ model: AppModel) { self.model = model }
  var provider: String { model?.settings.aiProvider ?? AssistantDefaults.provider }
  var modelID: String { model?.settings.aiModel ?? AssistantDefaults.model }
  var thinking: String { model?.settings.aiThinking ?? AssistantDefaults.thinking }
  var selectedModel: AssistantModelOption? { models.first { $0.provider == provider && $0.modelId == modelID } }
  var brokerTitle: String {
    if model?.isPreview == true { return "合成入口，不发起推理" }
    guard let model, let broker, let session = model.store.sessions[broker.sessionKey], session.snapshot.identity == broker else { return "尚无兼容模型入口" }
    return model.sessionTitle(session)
  }
  var canGenerate: Bool {
    guard !busy, !preparing, !prepared.isEmpty, let selectedModel, selectedModel.thinkingLevels.contains(thinking),
      Set(prepared.map { $0.identity.sessionKey }) == selectedKeys, extra.utf8.count <= 4096,
      let model, let broker, model.store.sessions[broker.sessionKey]?.snapshot.identity == broker,
      model.store.sessions[broker.sessionKey]?.connection == .connected else { return false }
    guard prepared.allSatisfy({ model.store.sessions[$0.identity.sessionKey]?.snapshot.identity == $0.identity }) else { return false }
    let sources = prepared.map(\.source)
    guard !AssistantPrivacy.sensitive(sources: sources, extra: extra), let size = try? JSONEncoder().encode(sources).count else { return false }
    return size + extra.utf8.count <= 32768
  }
  var resultIsCurrent: Bool {
    guard let model else { return false }
    return resultSources.allSatisfy { model.store.sessions[$0.identity.sessionKey]?.snapshot.identity == $0.identity }
  }
  var canApplyGroups: Bool { !busy && !(analysis?.groups.isEmpty ?? true) && resultIsCurrent }
  func seedPreviewResult() {
    guard let model, model.isPreview, let session = model.sessions.first else { return }
    let source = AssistantSource(ref: "S1", title: model.sessionTitle(session), project: "synthetic", status: "合成状态", tools: [], messages: [AssistantTextMessage(id: "synthetic-preview", role: "user", text: "这是明确的合成预览，不读取真实会话。")])
    selectedKeys = [session.snapshot.identity.sessionKey]
    prepared = [PreparedAssistantSource(identity: session.snapshot.identity, source: source, note: "合成上下文")]
    resultSources = prepared
    let raw = #"{"overview":"这是合成的 AI 总览，仅展示界面结构，不代表真实业务进度。","summaries":[{"ref":"S1","text":"依据明确的合成输入形成示例摘要，不推断测试、合并或部署成功。"}],"groups":[{"name":"合成工作组","refs":["S1"],"reason":"由用户主动采纳，本机显示标签不改变原工作。"}]}"#
    analysis = try? JSONDecoder().decode(AssistantAnalysis.self, from: Data(raw.utf8))
    generatedAt = Date(); resultModel = "合成示例 · " + AssistantDefaults.provider + "/" + AssistantDefaults.model + " · medium"
    notice = "合成 AI 预览：没有真实模型调用或真实消息读取。"
  }
  func setExtra(_ value: String) {
    guard value.utf8.count <= 4096 else { notice = "补充说明最多4KiB，之前的内容已保留。"; return }
    extra = value
  }
  func choose(_ key: String, selected: Bool) {
    guard !busy && !preparing else { return }
    if selected { if selectedKeys.count < 8 { selectedKeys.insert(key) } else { notice = "每次最多分析8个明确选中的会话。" } }
    else { selectedKeys.remove(key) }
    prepared = []; analysis = nil
  }
  func refreshModels() {
    guard let model, !busy, !loadingModels else { return }
    if model.isPreview {
      models = [AssistantModelOption(provider: AssistantDefaults.provider, modelId: AssistantDefaults.model, name: "合成模型预览", thinkingLevels: ["off", "low", "medium", "high"])]; notice = "合成预览不会发起真实模型调用"; return
    }
    let candidates = model.sessions.filter { $0.connection == .connected && $0.snapshot.capabilities.queries.contains("assistant") }
    guard let entry = candidates.first(where: { $0.snapshot.identity == model.current?.snapshot.identity }) ?? candidates.first else {
      models = []; broker = nil; notice = "尚无支持 AI 的 Pi 接入。正常新会话加载新版桥接后可用，不会强制重载已有工作。"; return
    }
    broker = entry.snapshot.identity; loadingModels = true
    var payload = AssistantPayload(operation: "models"); payload.provider = provider; payload.modelId = modelID
    if request(payload, identity: entry.snapshot.identity) == nil { loadingModels = false }
  }
  func prepare() {
    guard let model, !busy, !preparing else { return }
    let selected = model.sessions.filter { selectedKeys.contains($0.snapshot.identity.sessionKey) && $0.connection == .connected }
    guard !selected.isEmpty, selected.count <= 8, selected.count == selectedKeys.count else { notice = "请明确选择1至8个已接入会话。"; return }
    prepared = selected.enumerated().map { index, session in
      let source = AssistantSource(ref: "S\(index + 1)", title: AssistantPrivacy.bounded(model.sessionTitle(session), bytes: 128), project: AssistantPrivacy.bounded(Presentation.project(session.snapshot), bytes: 128), status: Presentation.status(session).title, tools: Array(session.snapshot.tools.prefix(3)))
      return PreparedAssistantSource(identity: session.snapshot.identity, source: source, note: "尚未读取近期文本")
    }
    analysis = nil; preparing = true
    for item in prepared {
      guard let session = model.store.sessions[item.identity.sessionKey], session.snapshot.identity == item.identity else { continue }
      if model.isPreview { updateContext(ref: item.id, messages: [AssistantTextMessage(id: "synthetic-text", role: "user", text: "这是明确的合成上下文，不是业务会话。")], note: "合成预览"); continue }
      guard session.snapshot.capabilities.queries.contains("assistant") else { updateContext(ref: item.id, messages: [], note: "旧桥接未提供近期文本，仅使用状态元数据"); continue }
      _ = request(AssistantPayload(operation: "context"), identity: item.identity, ref: item.id)
    }
    preparing = pending.values.contains { $0.operation == "context" }
    notice = preparing ? "正在读取所选当前分支的有界文本；不会扫描历史目录。" : "上下文已准备，可预览并移除消息。"
  }
  func removeMessage(ref: String, id: String) {
    guard !busy, let index = prepared.firstIndex(where: { $0.id == ref }) else { return }
    prepared[index].source.messages.removeAll { $0.id == id }; analysis = nil
  }
  private func updateContext(ref: String, messages: [AssistantTextMessage], note: String) {
    guard let index = prepared.firstIndex(where: { $0.id == ref }) else { return }
    prepared[index].source.messages = messages; prepared[index].note = note
  }
  func generate(force: Bool = false) {
    guard let model else { return }
    if model.isPreview { notice = "合成预览：未递送真实 AI 请求"; return }
    guard canGenerate, let broker else { notice = "请检查模型/思考档、当前运行及上下文预算；疑似敏感内容不会发送。"; return }
    var payload = AssistantPayload(operation: "analyze")
    payload.provider = provider; payload.modelId = modelID; payload.thinking = thinking; payload.sources = prepared.map(\.source); payload.extra = extra
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    guard let bytes = try? encoder.encode(payload), bytes.count <= 32768 else { notice = "上下文超过32KiB，请移除消息或减少所选会话。"; return }
    // Identity stays local: equal text from a replacement runtime is not the same input.
    guard let cacheBytes = try? encoder.encode(CacheInput(request: payload, broker: broker, identities: prepared.map(\.identity))) else { return }
    let fingerprint = NotificationTarget.hash(String(decoding: cacheBytes, as: UTF8.self))
    if !force, let cached, cached.fingerprint == fingerprint, cached.sources.map(\.identity) == prepared.map(\.identity), Date().timeIntervalSince(cached.at) < 600 {
      analysis = cached.analysis; generatedAt = cached.at; resultModel = cached.model; resultSources = cached.sources
      notice = "相同输入已有缓存结果，未再次调用模型。"; return
    }
    resultSources = prepared; resultModel = provider + "/" + modelID + " · " + thinking
    generationFingerprint = fingerprint; busy = true; analysis = nil
    generation = request(payload, identity: broker)
    if generation == nil { busy = false }
    else { submittedExtra = extra; notice = "AI 分析请求已发出；原会话继续独立运行。" }
  }
  func cancel() {
    guard let id = generation, let job = pending[id], busy else { return }
    var payload = AssistantPayload(operation: "cancel"); payload.cancelID = id
    _ = request(payload, identity: job.identity)
    notice = "已请求取消此 AI 请求，正在等待回执；已发生用量不保证撤销。"
  }
  @discardableResult private func request(_ payload: AssistantPayload, identity: Identity, ref: String? = nil) -> String? {
    guard let model, pending.count < 16 else { return nil }
    let id = UUID().uuidString
    pending[id] = Pending(identity: identity, operation: payload.operation, ref: ref, deadline: Date().timeIntervalSince1970 * 1000 + (payload.operation == "analyze" ? 135_000 : 15_000))
    guard (transport?(payload, identity, id) ?? model.sendAssistant(payload, identity: identity, requestID: id)) else { pending.removeValue(forKey: id); notice = "目标或请求不可用，未自动重发。"; return nil }
    return id
  }
  func receive(_ record: WireRecord) {
    guard let id = record.requestId, let job = pending[id], job.identity == record.identity, let payload = record.assistant, payload.operation == job.operation else { return }
    if payload.status == "pending" { return }
    pending.removeValue(forKey: id)
    switch job.operation {
    case "models":
      loadingModels = false
      if payload.status == "ok" { models = (payload.models ?? []).filter { !["cphone", "zooapi"].contains($0.provider.lowercased()) }; notice = "已读取 Pi 注册的可用模型；未发起推理调用。" }
      else { models = []; notice = message(payload.code) }
    case "context":
      if let ref = job.ref {
        let current = model?.store.sessions[job.identity.sessionKey]?.snapshot.identity == job.identity
        updateContext(ref: ref, messages: current && payload.status == "ok" ? payload.messages ?? [] : [], note: current && payload.status == "ok" ? (payload.partial == true ? "有界近期文本，存在截断或已排除内容" : "当前分支近期用户/助手文本") : "近期文本不可用；未使用其他运行代替")
      }
      preparing = pending.values.contains { $0.operation == "context" }
      if !preparing { notice = "请预览待发送内容；可移除消息，程序不能识别所有敏感信息。" }
    case "analyze":
      guard generation == id else { return }
      generation = nil; busy = false
      let refs = Set(resultSources.map { $0.source.ref })
      if payload.status == "ok", let output = payload.analysis, output.valid(for: refs) {
        analysis = output; generatedAt = Date(); notice = "AI 建议已返回，不是执行或验收结论。"
        if resultIsCurrent { cached = Cached(fingerprint: generationFingerprint, sources: resultSources, analysis: output, at: generatedAt!, model: resultModel) }
      } else { notice = message(payload.code) }
      var hasReportedTokens = false
      if let usage = payload.usage { hasReportedTokens = usage.input > 0 || usage.output > 0 || usage.cacheRead > 0 || usage.cacheWrite > 0 }
      model?.recordAssistantUsage(payload.usage, unconfirmed: payload.possibleUsage == true || payload.status == "unknown" || (payload.status == "ok" && !hasReportedTokens))
    case "cancel": if busy { notice = "取消请求已受理；等待原 AI 请求终态，不影响业务 Pi。" }
    default: break
    }
  }
  func applyGroups() {
    guard canApplyGroups, let analysis, let model else { notice = "结果所属运行已更新，请重新准备和分析。"; return }
    let byRef = Dictionary(uniqueKeysWithValues: resultSources.map { ($0.id, $0.identity) })
    let changes = analysis.groups.flatMap { group in group.refs.compactMap { ref in byRef[ref].map { ($0, group.name) } } }
    notice = model.assignGroups(changes) ? "已采纳为本机工作标签，未发送任何业务控制。" : "分组未应用：数量、名称或运行身份已变化。"
  }
  func tick(now: Double) {
    for (id, job) in pending where now >= job.deadline || model?.store.sessions[job.identity.sessionKey]?.snapshot.identity != job.identity || model?.store.sessions[job.identity.sessionKey]?.connection != .connected {
      pending.removeValue(forKey: id)
      if job.operation == "analyze" && generation == id {
        generation = nil; busy = false; notice = "AI 结果未确认，可能已有用量；未自动重发。"; model?.recordAssistantUsage(nil, unconfirmed: true)
      }
      if job.operation == "models" { loadingModels = false; notice = "模型入口未返回，请检查接入健康。" }
      if job.operation == "context", let ref = job.ref { updateContext(ref: ref, messages: [], note: "当前运行文本未返回") }
    }
    preparing = pending.values.contains { $0.operation == "context" }
  }
  func stop() {
    if busy { cancel(); model?.recordAssistantUsage(nil, unconfirmed: true) }
    pending.removeAll(); generation = nil; busy = false
  }
  private func message(_ code: String?) -> String {
    switch code {
    case "model-unavailable": return "指定模型不在此 Pi 的可用注册表中，未静默换模。"
    case "thinking-unsupported": return "所选模型不支持当前思考档，请明确选择支持的档位。"
    case "context-sensitive": return "检测到疑似敏感内容，本次未调用模型；请移除或改写。"
    case "context-budget": return "上下文超过预算，请移除消息或减少所选会话。"
    case "cancel-or-timeout": return "本次 AI 已取消或超时，结果/用量可能未确认；未自动重发。"
    case "analysis-in-flight": return "模型入口已有一个 AI 请求，请等待或取消。"
    default: return "AI 请求未能确认完整结果；未自动换模、重试或控制业务 Pi。"
    }
  }
}
