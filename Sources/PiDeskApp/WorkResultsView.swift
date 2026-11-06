import PiDeskCore
import SwiftUI

struct WorkResultsSection: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    if !model.workResults.isEmpty {
      LazyVStack(alignment: .leading, spacing: 12) {
        Text("工作记录").font(.headline)
        WorkObservationMeaning()
        if model.workResults.count > 32 { Text("总览显示前32个已观察工作引用；其余见来源会话。").font(.caption2).foregroundStyle(.secondary) }
        ForEach(Array(model.workResults.prefix(32))) { group in
          DeskCard { WorkRecordCard(group: group, navigation: true) }
        }
      }
    }
  }
}
private struct WorkObservationMeaning: View {
  var body: some View {
    DisclosureGroup("状态说明：进度不是验收，产物不等于任务完成") {
      Text("工作只按原始引用归组。每份记录保留原来源、阶段、head和时刻；已读、决策已解决、进度或Todo完成都不授予执行权限。不同来源不合成整体完成率。")
    }.font(.caption2).foregroundStyle(.secondary)
  }
}
private struct WorkRecordCard: View {
  let group: WorkResultGroup
  var navigation = false
  var body: some View {
    let stages = WorkCardPresentation.stages(group)
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(group.id.kindTitle + " · " + group.id.key).font(.headline).textSelection(.enabled)
        Text(group.id.owner + " · 原任务标题未提供").font(.caption2).foregroundStyle(.secondary)
      }
      if stages.isEmpty { WorkInfoRow(label: "阶段 / PR", value: "原来源未提供") }
      ForEach(Array(stages.prefix(4))) { stage in WorkStageCard(stage: stage, navigation: navigation) }
      if stages.count > 4 {
        DisclosureGroup("其他原始绑定（\(stages.count - 4)）") {
          ForEach(Array(stages.dropFirst(4))) { stage in WorkStageCard(stage: stage, navigation: navigation) }
        }.font(.caption)
      }
      if !group.handoffs.isEmpty {
        DisclosureGroup("原交接下一步（\(group.handoffs.count)份记录）") {
          ForEach(group.handoffs) { entry in
            WorkHandoffRow(handoff: entry.handoff)
            WorkSourceLine(reporter: entry.reporter, connected: entry.connected, observedAt: entry.observedAt, navigation: navigation)
          }
        }.font(.caption)
      }
      if !group.decisions.isEmpty {
        DisclosureGroup("原决策状态（\(group.decisions.count)个来源，不跨来源求和）") {
          ForEach(group.decisions) { entry in
            MissionDecisionRecordView(record: entry.record)
            WorkSourceLine(reporter: entry.reporter, connected: entry.connected, observedAt: entry.record.observedAt, navigation: navigation)
          }
        }.font(.caption)
      }
      VStack(alignment: .leading, spacing: 5) {
        WorkInfoRow(label: "需你处理", value: WorkCardPresentation.inputTitle(group))
        if !group.inputs.isEmpty {
          Text("仅原生输入等待；工作关联由调用方声明，不是已认证的任务归属。").font(.caption2).foregroundStyle(.secondary)
          ForEach(group.inputs) { entry in
            WorkSourceLine(reporter: entry.reporter, connected: true, observedAt: entry.input.startedAt, navigation: true)
          }
        }
      }
    }
  }
}
private struct WorkInfoRow: View {
  let label: String
  let value: String
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
      Text(value).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }.font(.caption)
  }
}
private struct WorkStageCard: View {
  let stage: WorkStageSummary
  var navigation: Bool
  var body: some View {
    let binding = stage.id.binding, progress = stage.latestProgress, result = stage.latestResult
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        Text(stage.phaseTitle).font(.subheadline.weight(.medium)).foregroundStyle(stage.hasUncertainty ? Color.orange : Color.primary)
        Spacer(minLength: 8)
        Text(stage.scopeTitle).font(.caption2).foregroundStyle(.secondary)
      }
      if let progress, let url = progress.progress.pullRequestURL {
        HStack(alignment: .firstTextBaseline) {
          Text("关联 PR").foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
          Link(progress.progress.repository + " #" + String(progress.progress.pullRequest), destination: url)
            .accessibilityLabel("打开原PR " + progress.progress.repository + " " + String(progress.progress.pullRequest))
        }.font(.caption)
      } else { WorkInfoRow(label: "关联 PR", value: "原来源未提供") }
      WorkInfoRow(label: "记录 head", value: binding.headSha.map { String($0.prefix(12)) } ?? "未提供")
      WorkInfoRow(label: "等待来源", value: stage.waitTitle)
      WorkInfoRow(label: "原已验记录", value: stage.resultTitle)
      WorkInfoRow(label: "原下一步", value: stage.nextTitle)
      if let progress {
        WorkSourceLine(reporter: progress.reporter, connected: progress.connected, observedAt: progress.progress.observedAt, navigation: navigation, kind: "进度")
      }
      if let result {
        WorkSourceLine(reporter: result.reporter, connected: result.connected, observedAt: result.observedAt, navigation: navigation && progress == nil, kind: "结果")
      }
      if progress == nil && result == nil, let handoff = stage.latestHandoff {
        WorkSourceLine(reporter: handoff.reporter, connected: handoff.connected, observedAt: handoff.observedAt, navigation: navigation, kind: "交接")
      }
      let count = stage.historicalProgress.count + stage.historicalResults.count
      if count > 0 {
        DisclosureGroup("同一绑定的先前观察（\(count)）") {
          ForEach(stage.historicalProgress) { entry in
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.progress.phaseTitle + " · " + entry.progress.waitTitle)
              Text("原下一步：" + entry.progress.nextActionTitle)
              WorkSourceLine(reporter: entry.reporter, connected: entry.connected, observedAt: entry.progress.observedAt, navigation: false, kind: "进度")
            }.padding(.vertical, 4)
          }
          ForEach(stage.historicalResults) { entry in
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.result.statusTitle)
              if entry.result.decision != "deliverable" { Text(entry.result.reasonTitle) }
              Text("原件引用 · " + (entry.result.resultRef ?? "未提供")).textSelection(.enabled)
              WorkSourceLine(reporter: entry.reporter, connected: entry.connected, observedAt: entry.observedAt, navigation: false, kind: "结果")
            }.padding(.vertical, 4)
          }
        }.font(.caption2).foregroundStyle(.secondary)
      }
      DisclosureGroup("来源绑定与原件引用") {
        VStack(alignment: .leading, spacing: 4) {
          Text("观察来源：" + stage.id.reporter.nativeSessionId)
          Text("运行代际：" + stage.id.reporter.runtimeEpoch)
          Text("观察代际：" + stage.id.observerEpoch)
          Text("原 session：" + binding.sessionId)
          Text("原 run：" + binding.runId + " · revision \(binding.revision)")
          if let head = binding.headSha { Text("原 head：" + head) }
          if let result {
            Text("原件引用：" + (result.result.resultRef ?? "未提供"))
            Text("原结果原因：" + result.result.reasonTitle)
          }
          if let progress { Text("原进度原因：" + progress.progress.waitReason) }
          Text("除明确关联的PR外，原件仅提供引用；不把引用猜成文件或网址。")
        }.textSelection(.enabled)
      }.font(.caption2).foregroundStyle(.secondary)
    }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }
}
private struct WorkSourceLine: View {
  let reporter: Identity
  let connected: Bool
  let observedAt: Double?
  var navigation: Bool
  var kind = "记录"
  @EnvironmentObject var model: AppModel
  private var timeLabel: String {
    guard let observedAt else { return "原" + kind + " · 时间未提供" }
    let formatted = Date(timeIntervalSince1970: observedAt / 1000).formatted(date: .abbreviated, time: .standard)
    return "原" + kind + " · " + formatted
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(timeLabel)
        if !connected { Text("最后观测 · 非实时").foregroundStyle(.orange) }
      }
      HStack {
        Text("来源会话 · " + String(reporter.nativeSessionId.suffix(8)))
        if navigation {
          Spacer(minLength: 8)
          Button("查看来源会话") { model.select(reporter); model.navigate(to: "会话") }
            .disabled(model.store.sessions[reporter.sessionKey]?.snapshot.identity != reporter)
            .accessibilityLabel("查看来源会话 " + reporter.nativeSessionId)
          Button("来源终端") { model.openOriginal(identity: reporter) }
            .disabled(!model.canOpenOriginal(identity: reporter))
            .accessibilityLabel("定位来源终端 " + reporter.nativeSessionId)
            .help("只定位此观察来源会话，不冒充绑定中的其他session，也不执行或恢复任务")
        }
      }
    }.font(.caption2).foregroundStyle(.secondary)
  }
}
struct GovernanceCoverageLine: View {
  let session: SessionView
  var body: some View {
    Text(session.snapshot.governance?.coverageTitle ?? "工作结果：当前桥接未提供观测").font(.caption2).foregroundStyle(.secondary)
  }
}
struct GovernanceSessionDetail: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  var body: some View {
    let groups = WorkResultPortfolio.groups([session]), projection = session.snapshot.governance
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("工作记录与交接", systemImage: "doc.text.magnifyingglass").font(.headline)
        Spacer()
        Button("读取现有观察") { model.refreshWork(identity: session.snapshot.identity) }
          .disabled(session.connection != .connected || !session.snapshot.capabilities.queries.contains("work.refresh"))
          .help("只读取原owner内存观察，不重新执行、验收或调用模型")
      }
      GovernanceCoverageLine(session: session)
      Text(session.snapshot.codeProgress?.coverageTitle ?? "代码进度：当前桥接未提供").font(.caption2).foregroundStyle(.secondary)
      WorkObservationMeaning()
      if groups.isEmpty { Text("当前没有可关联工作的原始观察；缺失不等于零项或工作完成。").font(.caption).foregroundStyle(.secondary) }
      ForEach(groups) { group in WorkRecordCard(group: group) }
      if let projection {
        let unbound = projection.results.filter { $0.observation.binding == nil }
        if !unbound.isEmpty {
          DisclosureGroup("尚未绑定工作的原结果（\(unbound.count)）") {
            ForEach(unbound, id: \.seq) { item in Text(item.observation.reasonTitle + " · 原结果未知") }
          }.font(.caption)
        }
        let unmapped = projection.handoffs.filter { h in
          let old = h.observation.previous?.workRef, next = h.observation.successor?.workRef
          return old == nil && next == nil || (old != nil && next != nil && old != next)
        }
        if !unmapped.isEmpty {
          DisclosureGroup("尚未对应单一工作的交接（\(unmapped.count)）") {
            ForEach(unmapped, id: \.seq) { WorkHandoffRow(handoff: $0.observation) }
          }.font(.caption)
        }
        if projection.omittedObservations > 0 { Text("原结果窗口累计移出 \(projection.omittedObservations) 条记录，不是工作总数。").font(.caption2).foregroundStyle(.secondary) }
        if projection.omittedResults + projection.omittedHandoffs > 0 { Text("显示预算另省略 \(projection.omittedResults) 个结果、\(projection.omittedHandoffs) 个交接。").font(.caption2).foregroundStyle(.secondary) }
      }
      if let progress = session.snapshot.codeProgress, progress.omitted > 0 { Text("原进度窗口累计移出 \(progress.omitted) 条记录，不是PR总数。").font(.caption2).foregroundStyle(.secondary) }
      if let decisions = session.snapshot.missionDecisions, !groups.allSatisfy({ $0.decisions.isEmpty }) {
        if decisions.omittedMissions > 0 { Text("决策显示预算另省略 \(decisions.omittedMissions) 份当前记录。").font(.caption2).foregroundStyle(.secondary) }
        if decisions.evictedRecords > 0 { Text("决策窗口累计移出 \(decisions.evictedRecords) 份记录，不是去重工作总数。").font(.caption2).foregroundStyle(.secondary) }
      }
      if groups.allSatisfy({ $0.decisions.isEmpty }) { MissionDecisionSessionDetail(session: session) }
      IntercomRelationsDetail(session: session)
    }
  }
}
private struct WorkHandoffRow: View {
  let handoff: PiWorkHandoff
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(handoff.decision == "handoff_observed" ? "原生交接记录" : "交接关系待对账").font(.caption.weight(.medium))
      Text("原交接下一步：" + handoff.nextActionTitle + " · 尚未重新核验，不据此执行")
      DisclosureGroup("查看保留引用") {
        ForEach(Array(handoff.acceptedFactRefs.enumerated()), id: \.offset) { _, ref in Text("事实 · " + ref) }
        ForEach(Array(handoff.unresolvedEffectRefs.enumerated()), id: \.offset) { _, ref in Text("未决效果 · " + ref) }
        ForEach(Array(handoff.blockerRefs.enumerated()), id: \.offset) { _, ref in Text("阻塞 · " + ref) }
        Text("原因 · " + handoff.reasonCode)
      }.textSelection(.enabled)
    }.font(.caption2).foregroundStyle(.secondary)
  }
}
