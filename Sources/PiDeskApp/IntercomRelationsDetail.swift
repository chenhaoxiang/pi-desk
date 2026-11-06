import PiDeskCore
import SwiftUI

struct IntercomRelationsDetail: View {
  let session: SessionView
  var body: some View {
    DisclosureGroup("消息传输关联") {
      VStack(alignment: .leading, spacing: 8) {
        Text("仅来自本会话自然查询到的原生状态；这里不主动查询、不拼接其他来源，也不创建待办或人工提醒。").font(.caption2).foregroundStyle(.secondary)
        if let snapshot = session.snapshot.intercomRelations, !snapshot.records.isEmpty {
          if session.connection != .connected { Text("最后观测，来源已非实时").font(.caption2).foregroundStyle(.secondary) }
          ForEach(snapshot.records) { record in
            VStack(alignment: .leading, spacing: 5) {
              Text("消息 · " + record.messageId).font(.caption.weight(.medium)).textSelection(.enabled)
              if let relation = record.relations {
                Text(relation.summary).font(.caption)
                Text(record.replyTitle).font(.caption2).foregroundStyle(.secondary)
                if let id = relation.supersedes { Text("原生替换关联 → " + id).textSelection(.enabled) }
                if let id = relation.supersededBy { Text("被此消息替换 → " + id).textSelection(.enabled) }
                if let id = relation.replyTo { Text("原回复关联 → " + id).textSelection(.enabled) }
                if let id = relation.lateReplyTo { Text("迟答对应旧消息 → " + id).textSelection(.enabled) }
                DisclosureGroup("原始路由") {
                  Text("发送方 · " + relation.senderSessionId)
                  Text("接收方 · " + relation.recipientSessionId)
                  Text("这是 broker 路由标识，不等于 Pi 会话或任务归属。")
                }.font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
              } else { Text(record.unavailableTitle).font(.caption).foregroundStyle(.secondary) }
              if let time = record.sourceUpdatedAt { Text("原状态更新：" + Date(timeIntervalSince1970: time / 1000).formatted()).font(.caption2).foregroundStyle(.secondary) }
            }.font(.caption2).padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
          }
          if snapshot.omitted > 0 { Text("显示预算另省略 \(snapshot.omitted) 份当前记录。").font(.caption2) }
          if snapshot.evictedRecords > 0 { Text("观察窗口累计移出 \(snapshot.evictedRecords) 份记录；不是去重消息总数。").font(.caption2) }
        } else {
          Text("尚未采集消息关系，不代表没有替换或迟答。旧 broker 或旧桥接可能未提供；不会为补齐展示重载业务会话。").font(.caption).foregroundStyle(.secondary)
        }
        Text("传输匹配不代表业务答案适用、用户批准或任务完成；迟答也不等于原工作已撤销。").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}
