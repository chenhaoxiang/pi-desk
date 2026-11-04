import PiDeskCore
import SwiftUI

struct WorkResultsSection: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    if !model.workResults.isEmpty {
      LazyVStack(alignment: .leading, spacing: 10) {
        Text("原 owner 工作结果").font(.headline)
        if model.workResults.count > 32 { Text("总览显示前32个已观察工作引用；其他请在来源会话详情查看。").font(.caption2).foregroundStyle(.secondary) }
        Text("相同的 owner／类型／工作引用才合组；结果仅代表原来那个阶段，不折算整体完成率。").font(.caption).foregroundStyle(.secondary)
        ForEach(Array(model.workResults.prefix(32))) { group in
          DeskCard {
            VStack(alignment: .leading, spacing: 10) {
              Text(group.id.kindTitle + " · " + group.id.key).font(.headline).textSelection(.enabled)
              Text(group.id.owner).font(.caption).foregroundStyle(.secondary)
              ForEach(Array(group.entries.prefix(4))) { entry in
                VStack(alignment: .leading, spacing: 6) {
                  OwnerResultRow(result: entry.result)
                  HStack {
                    if !entry.connected { Text("来源已非实时").foregroundStyle(.orange) }
                    if let date = entry.observedAt { Text("原观察：" + Date(timeIntervalSince1970: date / 1000).formatted(date: .abbreviated, time: .shortened)) }
                    Spacer()
                    Button("查看来源会话") { model.select(entry.reporter); model.navigate(to: "会话") }
                      .disabled(model.store.sessions[entry.reporter.sessionKey]?.snapshot.identity != entry.reporter)
                  }.font(.caption2).foregroundStyle(.secondary)
                }
              }
              if group.entries.count > 4 { Text("另有 \(group.entries.count - 4) 条原观察，请在来源会话详情查看").font(.caption2).foregroundStyle(.secondary) }
            }
          }
        }
      }
    }
  }
}
struct GovernanceCoverageLine: View {
  let session: SessionView
  var body: some View {
    let projection = session.snapshot.governance
    Text(projection?.coverageTitle ?? "工作结果：当前桥接未提供观测")
      .font(.caption2).foregroundStyle(.secondary)
  }
}
struct GovernanceSessionDetail: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("工作结果与交接", systemImage: "doc.text.magnifyingglass").font(.headline)
        Spacer()
        Button("读取现有观察") { model.refreshWork(identity: session.snapshot.identity) }
          .disabled(session.connection != .connected || !session.snapshot.capabilities.queries.contains("work.refresh"))
          .help("只读取原owner内存观察，不重新执行、验收或调用模型")
      }
      GovernanceCoverageLine(session: session)
      if let p = session.snapshot.governance {
        if p.results.isEmpty && p.handoffs.isEmpty {
          Text(p.coverage == "not-applicable" ? "原 owner 明确此会话不在当前观察范围内；不会重载会话来补齐。" : "尚无可展示的原 owner 结果；不把产物存在、Todo完成或本轮结束当成已交付。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(p.results, id: \.seq) { item in
          let result = item.observation
          if let binding = result.binding {
            Text(binding.workRef.owner + " · " + binding.workRef.key).font(.subheadline.weight(.medium)).textSelection(.enabled)
          }
          OwnerResultRow(result: result)
        }
        ForEach(p.handoffs, id: \.seq) { item in
          let handoff = item.observation
          VStack(alignment: .leading, spacing: 6) {
            Text(handoff.decision == "handoff_observed" ? "已记录原生交接" : "交接关系待对账").font(.subheadline.weight(.medium))
            Text("原 owner 下一步：" + handoff.nextActionTitle + "；不因此执行或恢复任务。").font(.caption)
            Text("保留事实引用 \(handoff.acceptedFactRefs.count) · 未决效果 \(handoff.unresolvedEffectRefs.count) · 阻塞引用 \(handoff.blockerRefs.count)").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("查看原交接引用") {
              ForEach(Array(handoff.acceptedFactRefs.enumerated()), id: \.offset) { _, ref in Text("事实 · " + ref) }
              ForEach(Array(handoff.unresolvedEffectRefs.enumerated()), id: \.offset) { _, ref in Text("未决 · " + ref) }
              ForEach(Array(handoff.blockerRefs.enumerated()), id: \.offset) { _, ref in Text("阻塞 · " + ref) }
              Text("原因：" + handoff.reasonCode)
            }.font(.caption2).textSelection(.enabled)
            Text("接续阶段尚未重新核验，旧证据不自动沿用为当前证明。").font(.caption2).foregroundStyle(.secondary)
          }
        }
        if p.omittedObservations > 0 { Text("原观察窗口已移出 \(p.omittedObservations) 条历史记录；不是工作总数。").font(.caption2).foregroundStyle(.secondary) }
        if p.omittedResults + p.omittedHandoffs > 0 {
          Text("为保持有界响应，另有 \(p.omittedResults) 个结果、\(p.omittedHandoffs) 个交接未显示。").font(.caption).foregroundStyle(.orange)
        }
        if let at = p.observedAt { Text("原观察时间：" + Date(timeIntervalSince1970: at / 1000).formatted()).font(.caption2).foregroundStyle(.secondary) }
      } else {
        Text("此旧桥接没有工作结果字段；可正常使用现有Pi，不触发历史扫描或重新验收。").font(.caption).foregroundStyle(.secondary)
      }
      Text("这些是只读的原 owner 观察，不是当前执行权限；也不新增需要你确认的事项。").font(.caption2).foregroundStyle(.secondary)
    }
  }
}
private struct OwnerResultRow: View {
  let result: PiOwnerResult
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .top) {
        Text(result.binding?.stageTitle ?? "工作绑定未知").font(.caption.weight(.medium))
        Spacer()
        Text(result.statusTitle).font(.caption).foregroundStyle(result.decision == "deliverable" ? Color.primary : Color.secondary)
      }
      Text(result.scopeNote).font(.caption2).foregroundStyle(.secondary)
      if result.decision != "deliverable" { Text(result.reasonTitle).font(.caption).foregroundStyle(.orange) }
      DisclosureGroup("来源与绑定") {
        if let binding = result.binding {
          Text("run：" + binding.runId)
          Text("session：" + binding.sessionId)
          Text("revision：\(binding.revision)")
          if let head = binding.headSha { Text("head：" + head) }
        }
        if let ref = result.resultRef { Text("result：" + ref) }
        Text("原因：" + result.reasonCode)
      }.font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
    }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }
}
