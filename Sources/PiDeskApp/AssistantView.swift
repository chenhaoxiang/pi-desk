import PiDeskCore
import SwiftUI

private struct AssistantContextRow: View {
  let message: AssistantTextMessage
  let remove: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      DisclosureGroup {
        Text(message.text).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Text(message.role == "user" ? "用户文本" : "助手文本").font(.caption.weight(.medium))
          Text(String(message.text.prefix(80))).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
      }.font(.caption)
      Button("移除", action: remove).buttonStyle(.borderless).font(.caption2)
    }
  }
}
private struct AssistantSourceChoice: View {
  let title: String
  let detail: String
  @Binding var selected: Bool
  var body: some View {
    Toggle(isOn: $selected) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).fontWeight(.medium).lineLimit(2)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }.toggleStyle(.checkbox)
  }
}
struct AssistantPage: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject private var assistant: DeskAssistantClient
  @State private var section = "准备"
  init(model: AppModel) { _assistant = ObservedObject(wrappedValue: model.assistant) }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        intro
        Picker("AI 工作步骤", selection: $section) {
          Text("准备上下文").tag("准备")
          Text("AI 建议与用量").tag("结果")
        }.pickerStyle(.segmented).labelsHidden()
        if section == "准备" {
          modelCard
          selectionCard
          contextCard
          if assistant.busy { resultCard }
        } else {
          resultCard
          if assistant.analysis == nil && !assistant.busy { Text("尚无 AI 结果，请先准备所选上下文并明确发起分析。").foregroundStyle(.secondary).padding(20) }
          usageCard
        }
      }.padding(22)
    }.onAppear {
      assistant.refreshModels(force: false)
      if model.isPreview && !CommandLine.arguments.contains("--assistant-prepare-preview") { assistant.seedPreviewResult() }
      if assistant.analysis != nil { section = "结果" }
      if assistant.selectedKeys.isEmpty, let current = model.current, current.connection == .connected { assistant.choose(current.snapshot.identity.sessionKey, selected: true) }
    }.onChange(of: assistant.analysis != nil) { _, ready in if ready { section = "结果" } }
  }
  private var intro: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("总结与工作组织").font(.title3.weight(.semibold))
      Text("按需总结和建议工作分组；它没有工具，不会回答问题、修改 Pi 状态或代替验收。模型用量与业务 Pi 分开记录。").font(.caption).foregroundStyle(.secondary)
      Text(assistant.notice).font(.caption).foregroundStyle(.secondary)
    }
  }
  private var modelCard: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack { Text("分析模型").font(.subheadline.weight(.semibold)); Spacer(); Button("刷新注册模型") { assistant.refreshModels() }.disabled(assistant.loadingModels || assistant.busy) }
        VStack(alignment: .leading, spacing: 10) {
          Picker("Pi 注册模型", selection: Binding(get: { assistant.provider + "/" + assistant.modelID }, set: assistant.selectModel)) {
            ForEach(assistant.models) { option in Text(option.provider + " / " + option.modelId + " · " + option.name).tag(option.id) }
            if assistant.selectedModel == nil { Text(assistant.provider + " / " + assistant.modelID + "（尚未从 Pi 读取）").tag(assistant.provider + "/" + assistant.modelID) }
          }.pickerStyle(.menu).disabled(assistant.models.isEmpty || assistant.loadingModels)
          Picker("思考强度", selection: Binding(get: { assistant.thinking }, set: assistant.selectThinking)) {
            ForEach(assistant.selectedModel?.thinkingLevels ?? [assistant.thinking], id: \.self) { Text(Presentation.effort($0) + " · " + $0).tag($0) }
            if let selected = assistant.selectedModel, !selected.thinkingLevels.contains(assistant.thinking) { Text(Presentation.effort(assistant.thinking) + "（此模型不支持，请重新选择）").tag(assistant.thinking) }
          }.pickerStyle(.menu).disabled(assistant.selectedModel == nil)
          if assistant.loadingModels { ProgressView("正在读取 Pi 注册模型…").controlSize(.small) }
        }.disabled(assistant.busy)
        Text("默认：\(AssistantDefaults.provider)/\(AssistantDefaults.model) · medium。修改只影响 Pi Desk AI 助手，不修改业务 Pi 的模型或思考档。").font(.caption2).foregroundStyle(.secondary)
        if !assistant.models.isEmpty { Text("注册入口：\(assistant.brokerTitle)").font(.caption2).foregroundStyle(.secondary) }
      }
    }
  }
  private var selectionCard: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack { Text("选择要分析的会话").font(.subheadline.weight(.semibold)); Spacer(); Button("刷新名称") { model.refreshNativeSessionNames() }.disabled(assistant.busy || assistant.preparing); Text("\(assistant.selectedKeys.count)/8").font(.caption).foregroundStyle(.secondary) }
        ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
        ForEach(model.sessions.filter { $0.connection == .connected }, id: \.snapshot.identity) { session in
          sourceChoice(session).disabled(assistant.busy || assistant.preparing)
        }
        }
        }.frame(maxHeight: 220)
        HStack { Button("读取所选近期内容") { assistant.prepare() }.disabled(assistant.selectedKeys.isEmpty || assistant.busy || assistant.preparing); Button("分析") { assistant.generate(); if assistant.analysis != nil { section = "结果" } }.buttonStyle(.borderedProminent).disabled(!assistant.canGenerate) }
      }
    }
  }
  private func sourceChoice(_ session: SessionView) -> some View {
    let key = session.snapshot.identity.sessionKey
    let shortID = String(session.snapshot.identity.nativeSessionId.suffix(6))
    let detail = [Presentation.project(session.snapshot), Presentation.status(session).title, shortID].joined(separator: " · ")
    return AssistantSourceChoice(title: model.nativeSessionTitle(session), detail: detail,
      selected: Binding(get: { assistant.selectedKeys.contains(key) }, set: { assistant.choose(key, selected: $0) }))
  }
  private var contextCard: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack { Text("发送前预览").font(.subheadline.weight(.semibold)); Spacer(); Text("不会读取思考或工具原文").font(.caption).foregroundStyle(.secondary) }
        ForEach(assistant.prepared) { item in
          VStack(alignment: .leading, spacing: 7) {
            HStack { Text(item.source.title).font(.caption.weight(.semibold)); Spacer(); Text(item.note).font(.caption2).foregroundStyle(.secondary) }
            ForEach(item.source.messages) { message in
              AssistantContextRow(message: message) { assistant.removeMessage(ref: item.id, id: message.id) }
            }
          }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
        TextField("可选补充说明（同样会发送给所选模型）", text: Binding(get: { assistant.extra }, set: assistant.setExtra), axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).disabled(assistant.busy)
        if !assistant.prepared.isEmpty { Text("检查后再发送：疑似密钥/密码会被阻断，但程序不能识别所有敏感内容。").font(.caption2).foregroundStyle(.orange) }
      }
    }
  }
  private var usageCard: some View {
    DisclosureGroup("Pi Desk AI 已记录用量") {
      VStack(alignment: .leading, spacing: 9) {
        Text("请求 \(model.aiUsageCounters["requests"] ?? 0) · 结果/用量未确认 \(model.aiUsageCounters["unconfirmed"] ?? 0)")
        Text("输入 " + Presentation.count(Double(model.aiUsageCounters["input"] ?? 0)) + " · 输出 " + Presentation.count(Double(model.aiUsageCounters["output"] ?? 0)))
        Text("缓存读取 " + Presentation.count(Double(model.aiUsageCounters["cacheRead"] ?? 0)) + " · 写入 " + Presentation.count(Double(model.aiUsageCounters["cacheWrite"] ?? 0)))
        Text("仅本 App 收到的数值回执；未结算或退出期间可能未覆盖，不是账单，也不混入业务 Pi 用量。").foregroundStyle(.secondary)
      }.font(.caption).padding(.top, 8)
    }.font(.caption)
  }
  private func sourceTitle(_ ref: String) -> String { ref + " · " + (assistant.resultSources.first { $0.id == ref }?.source.title ?? "来源未提供") }
  private var resultCard: some View {
    Group {
      if let analysis = assistant.analysis {
        DeskCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack { Text("AI 建议").font(.subheadline.weight(.semibold)); Spacer(); Text(assistant.resultModel).font(.caption2).foregroundStyle(.secondary) }
            Text(analysis.overview).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            ForEach(analysis.summaries) { summary in VStack(alignment: .leading, spacing: 3) { Text(sourceTitle(summary.ref)).font(.caption.weight(.semibold)); Text(summary.text).font(.caption) } }
            if !analysis.groups.isEmpty {
              Divider(); Text("建议分组").font(.caption.weight(.semibold))
              ForEach(analysis.groups) { group in VStack(alignment: .leading, spacing: 3) { Text(group.name).font(.caption.weight(.semibold)); Text(group.refs.joined(separator: "、") + " · " + group.reason).font(.caption).foregroundStyle(.secondary) } }
              Button("采纳为本机分组标签") { assistant.applyGroups() }.buttonStyle(.bordered).disabled(!assistant.canApplyGroups)
              if !assistant.resultIsCurrent { Text("来源运行已更新，此建议不能应用到新运行。").font(.caption).foregroundStyle(.orange) }
            }
            HStack { if assistant.busy { ProgressView().controlSize(.small); Button("取消") { assistant.cancel() } }; Spacer(); Button("重新分析") { assistant.generate(force: true) }.disabled(assistant.busy || !assistant.canGenerate) }
            if let date = assistant.generatedAt { Text("生成完成：" + date.formatted()).font(.caption2).foregroundStyle(.secondary) }
            Text("仅是有来源的建议，不代表任务完成、测试通过、合并、部署或业务Pi状态。").font(.caption2).foregroundStyle(.secondary)
          }
        }
      } else if assistant.busy { DeskCard { HStack { ProgressView(); Text("AI 分析中；原会话继续独立运行。"); Spacer(); Button("请求取消") { assistant.cancel() } } } }
    }
  }
}
