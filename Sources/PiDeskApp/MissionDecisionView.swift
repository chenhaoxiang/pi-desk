import PiDeskCore
import SwiftUI

struct MissionDecisionRecordView: View {
  let record: MissionDecisionView
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(record.summary).font(.caption.weight(.medium))
      Text(record.scopeNote).font(.caption2).foregroundStyle(.secondary)
      if !record.decisions.isEmpty {
        DisclosureGroup("查看原决策状态") {
          ForEach(record.decisions) { decision in
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .top) {
                Text(decision.id).textSelection(.enabled)
                Spacer()
                Text(decision.statusTitle).foregroundStyle(.secondary)
              }
              if let intent = decision.intentTitle { Text(intent).foregroundStyle(.secondary).textSelection(.enabled) }
              if let replacement = decision.replacementTitle { Text(replacement).foregroundStyle(.secondary).textSelection(.enabled) }
            }
          }
        }.font(.caption)
      }
      if record.omitted > 0 { Text("另有 \(record.omitted) 项未展开；引用对象可能未显示，不能由替换意向推断旧项关闭。").font(.caption2).foregroundStyle(.secondary) }
      if let date = record.sourceUpdatedAt { Text("原记录更新时间：" + Date(timeIntervalSince1970: date / 1000).formatted()).font(.caption2).foregroundStyle(.secondary) }
    }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }
}
struct MissionDecisionSessionDetail: View {
  let session: SessionView
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("原工作决策记录").font(.subheadline.weight(.medium))
      if let snapshot = session.snapshot.missionDecisions, !snapshot.missions.isEmpty {
        if session.connection != .connected { Text("最后观测，来源已非实时").font(.caption2).foregroundStyle(.secondary) }
        ForEach(snapshot.missions, id: \.workRef) { record in
          Text(record.workRef.key).font(.caption).textSelection(.enabled)
          MissionDecisionRecordView(record: record)
        }
        if snapshot.omittedMissions > 0 { Text("显示预算另省略 \(snapshot.omittedMissions) 份当前记录。").font(.caption2).foregroundStyle(.secondary) }
        if snapshot.evictedRecords > 0 { Text("观察窗口累计移出 \(snapshot.evictedRecords) 份记录；不是去重后的工作总数。").font(.caption2).foregroundStyle(.secondary) }
      } else {
        Text("尚未收到原生 mission 决策快照，不代表没有未决事项。这里只观察自然工具结果，不主动读取任务库。").font(.caption).foregroundStyle(.secondary)
      }
      Text("未决不等于需要用户；答复记录不判断答案有效性，撤回或替换不撤销既有权限。正文、选项和答复未采集。").font(.caption2).foregroundStyle(.secondary)
    }
  }
}
