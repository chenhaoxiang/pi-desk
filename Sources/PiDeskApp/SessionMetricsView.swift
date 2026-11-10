import PiDeskCore
import SwiftUI

struct SessionMetricsView: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  var body: some View {
    let identity = session.snapshot.identity
    let usage = model.sessionUsage[identity.sessionKey]
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("会话记录与消耗").font(.subheadline.weight(.semibold))
        Spacer()
        Button("刷新会话统计") { model.refreshSessionReadings(force: true); model.refresh(identity: identity) }
          .disabled(session.connection != .connected).font(.caption)
      }
      Text(session.snapshot.nativeSessionMeta?.compactionTitle ?? "压缩次数：此运行尚未提供原生元数据").font(.caption)
      if session.connection != .connected { Text("原Pi来源已非实时；压缩与活动仅显示最后收到记录。").font(.caption2).foregroundStyle(.secondary) }
      if let usage, usage.session == UsageViewStateKey.hash(identity.sessionKey) {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
          row("该会话已记录总Token", usage.total)
          row("今日", usage.today)
          row("最近7天（含今日）", usage.last7)
          row("最近30天（含今日）", usage.last30)
        }.font(.caption)
        Text("已记录下界 · " + usage.timeZoneID + " · \(usage.recordCount)条去重记录；完整会话消耗尚未确认。").font(.caption2).foregroundStyle(.secondary)
        if usage.error != nil { Text("读取未确认，保留原上次结果；没有清零。").font(.caption2).foregroundStyle(.orange) }
        if let at = usage.refreshedAt { Text("统计读取于：" + at.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary) }
        DisclosureGroup("统计口径与覆盖") {
          VStack(alignment: .leading, spacing: 6) {
            Text("总Token=输入+输出+缓存读取+缓存写入；只计该会话已归因记录，不把继承或子任务额外消耗重复归入。")
            Text("与Token页共用唯一用量索引；本卡固定全部模型、实时/历史去重合计，不随全局筛选变化，也不与总页再次相加。近30天不是本月。")
            Text("未采集历史、未归因工具消耗或未提供usage的压缩等不补0。压缩为已加载原生记录数，含全部分支且可能含fork继承，不冒称本会话独立新增次数。")
            if let at = usage.earliestAt { Text("现有用量记录起点：" + at.formatted(date: .abbreviated, time: .standard)) }
            if !usage.reasons.isEmpty { Text("原用量采集还报告待核覆盖项；此处不是完整账单。") }
            if let at = session.snapshot.nativeSessionMeta?.observedAt { Text("原生元数据观察于：" + Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .standard) + "，不是活动时间。") }
            Text("旧运行缺可选原生字段时等待正常加载，不用零次代替未知，也不强制重载业务Pi。")
          }.font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }.font(.caption)
      } else { Text("正在读取该会话的既有用量记录；历史未采集不当零，也不把本次接入窗口当完整会话。").font(.caption).foregroundStyle(.secondary) }
    }.onAppear { model.refreshSessionReadings(force: true) }
      .onChange(of: identity) { _, _ in model.refreshSessionReadings(force: true) }
  }
  private func row(_ label: String, _ tokens: UsageTokenTotals) -> some View {
    let value = tokens.metric(.processing)
    return GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value.known ? (value.complete ? value.value.formatted() + "（已记录）" : "≥" + value.value.formatted() + "（部分字段未知）") : "该范围未有记录，完整用量未知").monospacedDigit()
    }
  }
}
