import PiDeskCore
import SwiftUI

struct HealthPage: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("先看哪一层未接入，再决定下一步；不会为诊断重启 Pi。").font(.subheadline).foregroundStyle(.secondary)
        if !model.sessions.isEmpty {
          Picker("查看会话", selection: Binding(get: { model.selected ?? "" }, set: { key in
            if let session = model.sessions.first(where: { $0.snapshot.identity.sessionKey == key }) { model.select(session.snapshot.identity) }
          })) {
            Text("请选择会话").tag("")
            ForEach(model.sessions, id: \.snapshot.identity) { session in Text(model.sessionTitle(session)).tag(session.snapshot.identity.sessionKey) }
          }.pickerStyle(.menu)
        }
        ForEach(model.healthRows) { row in
          DeskCard {
            VStack(alignment: .leading, spacing: 8) {
              Label(row.title, systemImage: row.tone == .red ? "exclamationmark.circle" : "info.circle").font(.subheadline.weight(.semibold))
                .foregroundStyle(row.tone.ink(dark: scheme == .dark))
              Text(row.detail).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        HStack {
          Button("检查通知许可") { model.checkNotificationStatus() }
          if let session = model.current {
            Button("刷新此会话状态") { model.refresh(identity: session.snapshot.identity) }.disabled(session.connection != .connected)
            Button("只读检查终端权限") { model.checkOriginalRoutePermission(identity: session.snapshot.identity) }.disabled(session.connection != .connected)
          }
        }.buttonStyle(.bordered).font(.caption)
        Text("需要输入、状态未知和统计缺口是不同问题；不通过扫描历史或猜窗口把提示消掉。").font(.caption).foregroundStyle(.secondary)
      }.padding(22)
    }
  }
}
