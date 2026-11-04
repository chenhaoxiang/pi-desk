import Foundation
import PiDeskCore

@main enum AssistantChecks {
  @MainActor static func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<5000 { if condition() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
    precondition(condition(), "bounded local SDK response missing")
  }
  @MainActor static func main() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/assistant-v1.json"))) as! [String: Any]
    let request = try Wire.decode(JSONSerialization.data(withJSONObject: fixture["request"]!))
    let response = try Wire.decode(JSONSerialization.data(withJSONObject: fixture["response"]!))
    precondition(request.assistant?.provider == AssistantDefaults.provider && request.assistant?.modelId == AssistantDefaults.model && request.assistant?.thinking == "medium")
    precondition(response.assistant?.analysis?.valid(for: ["S1"]) == true)
    precondition(AssistantPrivacy.sensitive("Authorization: Bearer " + "SYNTHETIC_CREDENTIAL") && AssistantPrivacy.sensitive("密码=" + "123456"))
    precondition(!AssistantPrivacy.sensitive("only registered model metadata"))
    let model = AppModel(); defer { model.stop() }
    var snapshot = try Wire.decode(Data(contentsOf: root.appendingPathComponent("Fixtures/wire-v1.json"))).snapshot!
    snapshot.capabilities.queries.append("assistant")
    snapshot.display.name = "Pi /name 的真实任务名"
    let connection = UUID()
    precondition(model.store.apply(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot), connection: connection, now: Date().timeIntervalSince1970 * 1000))
    model.select(snapshot.identity)
    var sent: [(AssistantPayload, Identity, String)] = []
    let client = DeskAssistantClient(transport: { payload, identity, id in sent.append((payload, identity, id)); return true })
    client.bind(model); defer { client.stop() }
    client.refreshModels()
    precondition(sent.count == 1 && sent[0].0.operation == "models")
    let option = AssistantModelOption(provider: AssistantDefaults.provider, modelId: AssistantDefaults.model, name: "Synthetic model", thinkingLevels: ["off", "medium"])
    let other = AssistantModelOption(provider: "registered-other", modelId: "other-model", name: "Other registered", thinkingLevels: ["low", "high"])
    var modelReply = AssistantPayload(operation: "models"); modelReply.status = "ok"; modelReply.models = [option, other]
    client.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: sent[0].2, assistant: modelReply))
    precondition(!client.loadingModels && client.selectedModel?.id == option.id)
    client.choose(snapshot.identity.sessionKey, selected: true)
    client.prepare()
    let contextRequest = sent.last!
    precondition(contextRequest.0.operation == "context" && contextRequest.1 == snapshot.identity)
    var contextReply = AssistantPayload(operation: "context"); contextReply.status = "ok"; contextReply.messages = [AssistantTextMessage(id: "fake-text", role: "user", text: "Explicit synthetic context")]
    client.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: contextRequest.2, assistant: contextReply))
    precondition(!client.preparing && client.prepared.count == 1 && client.canGenerate)
    _ = model.setAlias("只在Desk的旧别名", for: snapshot.identity)
    client.prepare()
    client.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: sent.last!.2, assistant: contextReply))
    precondition(client.prepared[0].source.title == snapshot.display.name && model.nativeSessionTitle(model.current!) == snapshot.display.name, "AI titles come from Pi /name, never a local alias or project hash")
    client.selectModel(other.id)
    precondition(client.provider == other.provider && client.modelID == other.modelId && client.thinking == "medium" && !client.canGenerate, "explicit model selection updates the pair without silently downgrading effort")
    client.selectThinking("high")
    precondition(client.canGenerate && client.thinking == "high")
    client.selectThinking("max")
    precondition(client.thinking == "high", "unsupported levels cannot be saved")
    client.selectModel(option.id); client.selectThinking("medium")
    precondition(client.canGenerate && client.selectedModel?.id == option.id)
    client.extra = "Synthetic extra"; precondition(client.hasUnsentExtra)
    let businessModelState = model.store.requests.count
    client.generate()
    let analysisRequest = sent.last!
    precondition(client.busy && analysisRequest.0.operation == "analyze" && analysisRequest.0.thinking == "medium" && !client.hasUnsentExtra)
    var pending = AssistantPayload(operation: "analyze"); pending.status = "pending"
    client.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: analysisRequest.2, assistant: pending))
    precondition(client.busy && client.analysis == nil && model.aiUsageCounters.isEmpty, "accepted is not completed or settled usage")
    let final = WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: analysisRequest.2, assistant: response.assistant)
    client.receive(final); client.receive(final)
    precondition(!client.busy && client.analysis != nil && model.aiUsageCounters["requests"] == 1 && model.aiUsageCounters["output"] == 20, "final receipt is accounted once and separate from business usage")
    precondition(client.canApplyGroups)
    client.applyGroups()
    precondition(model.workGroup(snapshot.identity) == "合成分组" && model.store.requests.count == businessModelState, "AI can only label local groups after explicit adoption")
    let callsBeforeCache = sent.count
    client.generate()
    precondition(sent.count == callsBeforeCache && !client.busy && model.aiUsageCounters["requests"] == 1, "same input reuses a bounded memory result, not another model call")
    model.settings.aiThinking = "max"
    client.generate(force: true)
    precondition(sent.count == callsBeforeCache && !client.busy, "unsupported thinking cannot silently downgrade")
    model.settings.aiThinking = "medium"
    client.extra = "密码=" + "123456"
    client.generate(force: true)
    precondition(sent.count == callsBeforeCache && !client.busy, "sensitive extra is blocked before transport")
    client.extra = "Synthetic extra"
    client.generate(force: true)
    let cancellable = sent.last!
    client.cancel()
    precondition(sent.last?.0.operation == "cancel" && sent.last?.0.cancelID == cancellable.2 && client.busy)
    var unknown = AssistantPayload(operation: "analyze"); unknown.status = "unknown"; unknown.possibleUsage = true; unknown.code = "cancel-or-timeout"
    client.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: cancellable.2, assistant: unknown))
    precondition(!client.busy && model.aiUsageCounters["unconfirmed"] == 1 && model.store.requests.count == businessModelState)
    client.generate(force: true)
    client.tick(now: Date().timeIntervalSince1970 * 1000 + 136000)
    precondition(!client.busy && model.aiUsageCounters["unconfirmed"] == 2, "lost result remains unconfirmed and is never automatically replayed")
    // A late, valid old result cannot mutate replacement runtime labels.
    client.generate(force: true)
    let staleRequest = sent.last!
    var replacement = snapshot; replacement.identity.runtimeEpoch = "replacement-ai-epoch"; replacement.seq += 1
    precondition(model.store.apply(WireRecord(kind: "hello", identity: replacement.identity, snapshot: replacement), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    client.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: staleRequest.2, assistant: response.assistant))
    let groupsBefore = model.sessionGroups
    precondition(!client.canApplyGroups)
    client.applyGroups()
    precondition(model.sessionGroups == groupsBefore && model.store.requests.count == businessModelState)
    // Broker B remains current while source A is replaced. Equal text cannot rebind cached E1 to E2.
    var brokerSnapshot = replacement; brokerSnapshot.identity.nativeSessionId = "stable-ai-broker"
    precondition(model.store.apply(WireRecord(kind: "hello", identity: brokerSnapshot.identity, snapshot: brokerSnapshot), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    model.select(brokerSnapshot.identity)
    var cacheRequests: [(AssistantPayload, Identity, String)] = []
    let scopedCache = DeskAssistantClient(transport: { payload, identity, id in cacheRequests.append((payload, identity, id)); return true })
    scopedCache.bind(model); defer { scopedCache.stop() }
    scopedCache.refreshModels()
    scopedCache.receive(WireRecord(kind: "assistant-response", identity: brokerSnapshot.identity, requestId: cacheRequests.last!.2, assistant: modelReply))
    scopedCache.choose(replacement.identity.sessionKey, selected: true); scopedCache.prepare()
    scopedCache.receive(WireRecord(kind: "assistant-response", identity: replacement.identity, requestId: cacheRequests.last!.2, assistant: contextReply))
    scopedCache.generate()
    let oldSourceRequest = cacheRequests.last!
    precondition(oldSourceRequest.1 == brokerSnapshot.identity)
    var newest = replacement; newest.identity.runtimeEpoch = "cache-source-new-epoch"; newest.seq += 1
    precondition(model.store.apply(WireRecord(kind: "hello", identity: newest.identity, snapshot: newest), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    scopedCache.receive(WireRecord(kind: "assistant-response", identity: brokerSnapshot.identity, requestId: oldSourceRequest.2, assistant: response.assistant))
    precondition(scopedCache.analysis != nil && !scopedCache.canApplyGroups)
    scopedCache.prepare()
    scopedCache.receive(WireRecord(kind: "assistant-response", identity: newest.identity, requestId: cacheRequests.last!.2, assistant: contextReply))
    let beforeNewRuntime = cacheRequests.count
    scopedCache.generate()
    precondition(cacheRequests.count == beforeNewRuntime + 1 && scopedCache.busy && scopedCache.analysis == nil, "old runtime result is not a cache hit even with identical model and source text")
    let newSourceRequest = cacheRequests.last!
    scopedCache.receive(WireRecord(kind: "assistant-response", identity: brokerSnapshot.identity, requestId: newSourceRequest.2, assistant: response.assistant))
    precondition(scopedCache.canApplyGroups && scopedCache.resultSources.first?.identity == newest.identity)
    let beforeSameRuntime = cacheRequests.count
    scopedCache.generate()
    precondition(cacheRequests.count == beforeSameRuntime && scopedCache.canApplyGroups, "same exact runtime retains normal cache reuse")
    scopedCache.generate(force: true)
    let beforeMissingUsage = model.aiUsageCounters["unconfirmed"] ?? 0
    var zeroUsage = response.assistant!
    zeroUsage.usage = try JSONDecoder().decode(AssistantUsage.self, from: Data(#"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}"#.utf8))
    zeroUsage.possibleUsage = false
    scopedCache.receive(WireRecord(kind: "assistant-response", identity: brokerSnapshot.identity, requestId: cacheRequests.last!.2, assistant: zeroUsage))
    precondition(scopedCache.analysis != nil && model.aiUsageCounters["unconfirmed"] == beforeMissingUsage + 1, "an SDK default zero usage is not a confirmed settlement")
    model.assistant.extra = "unsent assistant context"
    precondition(model.requiresDraftConfirmation, "AI extra participates in the same exit protection")
    model.assistant.extra = ""
    model.stop()
    // The real Node/SDK helper must expose choices with zero compatible online brokers.
    let node = ProcessInfo.processInfo.environment["PI_DESK_TEST_NODE"]!
    let sdkPath = root.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/index.js").path
    let helper = root.appendingPathComponent("Tests/PiDeskAppTests/LocalAssistantFixture.mjs").path
    let local = LocalAssistantTransport(installation: .init(node: node, sdk: sdkPath, helper: helper))
    let standalone = AppModel(localAssistant: local)
    defer { standalone.stop() }
    let localClient = standalone.assistant
    localClient.refreshModels()
    await waitUntil { !localClient.loadingModels }
    precondition(localClient.models.count == 2 && standalone.sessions.isEmpty, "registered model choices do not depend on a new business Pi or bridge")
    localClient.selectModel("desk-local-fixture/beta"); localClient.selectThinking("off")
    precondition(localClient.modelID == "beta" && localClient.thinking == "off" && standalone.settings.aiProvider == "desk-local-fixture")
    var legacySource = snapshot; legacySource.identity.nativeSessionId = "old-bridge-source"; legacySource.capabilities.queries.removeAll { $0 == "assistant" }
    precondition(standalone.store.apply(WireRecord(kind: "hello", identity: legacySource.identity, snapshot: legacySource), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    localClient.choose(legacySource.identity.sessionKey, selected: true); localClient.prepare()
    precondition(localClient.prepared.first?.source.messages.isEmpty == true && localClient.prepared.first?.note.contains("旧桥接") == true && localClient.canGenerate)
    localClient.generate()
    await waitUntil { !localClient.busy }
    precondition(localClient.analysis?.overview == "Synthetic local summary" && standalone.store.requests.isEmpty, "tool-free local SDK analysis works with explicitly shown metadata-only old sources")
    localClient.setExtra("SYNTHETIC_HOLD"); localClient.generate(force: true)
    precondition(localClient.busy)
    localClient.cancel()
    await waitUntil { !localClient.busy }
    precondition((standalone.aiUsageCounters["unconfirmed"] ?? 0) == 1 && standalone.store.requests.isEmpty, "cancel crosses real subprocess stdin and aborts only the isolated AI request")
    standalone.stop()
    var fallbackPackets: [(AssistantPayload, Identity, String)] = []
    let fallbackClient = DeskAssistantClient(transport: { p, i, r in fallbackPackets.append((p, i, r)); return true })
    let failedHelper = root.appendingPathComponent("Tests/PiDeskAppTests/LocalAssistantFailureFixture.mjs").path
    let broken = LocalAssistantTransport(installation: .init(node: node, sdk: sdkPath, helper: failedHelper))
    let fallbackModel = AppModel(localAssistant: broken, assistantClient: fallbackClient)
    defer { fallbackModel.stop() }
    precondition(fallbackModel.store.apply(WireRecord(kind: "hello", identity: snapshot.identity, snapshot: snapshot), connection: UUID(), now: Date().timeIntervalSince1970 * 1000))
    fallbackModel.settings.aiProvider = other.provider; fallbackModel.settings.aiModel = other.modelId; fallbackModel.settings.aiThinking = "high"
    fallbackClient.refreshModels()
    await waitUntil { !fallbackPackets.isEmpty }
    precondition(fallbackPackets.count == 1 && fallbackPackets[0].0.operation == "models" && fallbackPackets[0].1 == snapshot.identity, "failed SDK directory probe falls back once to the exact compatible online registry")
    fallbackClient.receive(WireRecord(kind: "assistant-response", identity: snapshot.identity, requestId: fallbackPackets[0].2, assistant: modelReply))
    precondition(!fallbackClient.loadingModels && fallbackClient.models.count == 2 && fallbackClient.provider == other.provider && fallbackClient.modelID == other.modelId && fallbackClient.thinking == "high")
    precondition(fallbackModel.store.requests.isEmpty && fallbackPackets.allSatisfy { $0.0.operation == "models" }, "directory fallback neither changes model choice nor resubmits an analysis")
    print("Assistant checks passed: shared DTO, exact registry/context routes, medium selection, sensitive-input preflight, explicit labeling, numeric-only usage, dedup/cache, cancel/timeout and runtime freshness.")
  }
}
