import AppKit
import PiDeskCore
import SwiftUI

/// Uses the same current portfolio and UsageLedger aggregate as their existing
/// pages. No second query/store/model or implied all-day business report.
struct WorkObservationBriefView: View {
  @EnvironmentObject var model: AppModel
  @State private var copied = false
  @State private var expanded: Bool
  init(expanded: Bool = false) { _expanded = State(initialValue: expanded) }
  var body: some View {
    let brief = WorkObservationBrief(groups: model.workResults, sessions: model.sessions)
    DisclosureGroup("当前观察小结 · \(brief.observedWorkCount) 个工作引用", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        Text("\(brief.nativeInputCount) 项原生输入 · \(brief.inputLinkedWorkCount) 个工作有声明关联的输入").font(.caption.weight(.medium))
        Text(brief.oldestInputTitle()).font(.caption)
        Text("\(brief.reportingSourceCount)/\(brief.onlineSourceCount) 在线来源已提供明确工作引用观察（含待核）。仅已收到窗口，不是全天履历或交付率。").font(.caption2).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text("既有用量口径（不分摊到工作）").font(.caption.weight(.medium))
          Text(UsageObservationText.scope(model.aggregate)).font(.caption2).foregroundStyle(.secondary)
          Text(UsageObservationText.metric(model.aggregate)).font(.caption)
          Text(UsageObservationText.freshness(model.aggregate)).font(.caption2).foregroundStyle(.secondary)
          Text("费用、单工作成本及经营收益：未提供原始来源，不推算。").font(.caption2).foregroundStyle(.secondary)
          if model.aggregate.error != nil { Text("用量读取未确认，保留原上次结果；详见Token页。").font(.caption2).foregroundStyle(.orange) }
        }
        HStack {
          Button(copied ? "再次复制当前摘要" : "复制当前观察摘要") {
            let current = WorkObservationBrief(groups: model.workResults, sessions: model.sessions)
            let usage = model.aggregate
            let text = current.text() + "\n\n用量口径：" + UsageObservationText.text(usage) + "\n费用/工作成本/经营收益：来源未提供，不推算。"
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
          }
          Button("查看同口径用量") { model.navigate(to: "Token") }
        }.buttonStyle(.bordered).font(.caption)
        Text("只复制当前已接入的原始引用、阶段与来源范围；不触发模型、刷新原件、自动日报或业务操作。").font(.caption2).foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }.font(.caption)
  }
}
