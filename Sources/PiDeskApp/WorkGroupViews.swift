import AppKit
import PiDeskCore
import SwiftUI

struct WorkGroupControl: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  var body: some View {
    Menu {
      Button("未分组") { _ = model.assignGroups([(session.snapshot.identity, "")]) }
      ForEach(model.workGroups, id: \.self) { name in
        Button(name) { _ = model.assignGroups([(session.snapshot.identity, name)]) }
      }
      Divider()
      Button("新建／管理工作组") { model.modal = .groups }
    } label: {
      Label(model.workGroup(session.snapshot.identity) ?? "分组", systemImage: "folder").lineLimit(1)
    }.menuStyle(.borderlessButton).fixedSize().help("只改变本机组织标签，不改变会话身份或执行")
  }
}

struct WorkGroupsView: View {
  @EnvironmentObject var model: AppModel
  @State private var name = ""
  @State private var issue = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("工作分组").font(.title3.weight(.semibold)); Spacer(); Button("关闭") { model.modal = nil }.keyboardShortcut(.cancelAction) }
      Text("由你给工作贴标签，不根据 cwd 推断真实影响仓库；移除标签不删除或停止 Pi。").font(.caption).foregroundStyle(.secondary)
      HStack {
        TextField("新分组名称", text: $name).textFieldStyle(.roundedBorder)
        Button("分配给当前会话") {
          guard let session = model.current else { return }
          if model.assignGroups([(session.snapshot.identity, name)]) { name = ""; issue = "" }
          else { issue = "名称最多64字节，最多16个分组/64个归属；目标更新后请重新选择。" }
        }.disabled(model.current == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if model.current == nil { Text("请先选择一个准确会话，再为它命名分组。").font(.caption).foregroundStyle(.secondary) }
      if !issue.isEmpty { Text(issue).font(.caption).foregroundStyle(.orange) }
      ScrollView {
        LazyVStack(spacing: 10) {
          if model.workGroups.isEmpty { Text("尚未设置工作分组").foregroundStyle(.secondary).padding(30) }
          ForEach(model.workGroups, id: \.self) { group in
            HStack {
              Label(group, systemImage: "folder")
              Text("\(model.sessionGroups.values.filter { $0 == group }.count) 个已保存标签").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("移除分组标签", role: .destructive) { model.removeWorkGroup(group) }
            }.padding(12)
          }
        }
      }
    }.padding(22).frame(width: 640, height: 460)
  }
}

private struct DisplayChoice: Identifiable { let id: String; let name: String }
struct DisplayPreferencesView: View {
  @EnvironmentObject var model: AppModel
  private var screens: [DisplayChoice] {
    NSScreen.screens.enumerated().compactMap { index, screen in
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      return DisplayChoice(id: "display:\(id.uint32Value)", name: "显示器 \(index + 1) · \(screen.localizedName)")
    }
  }
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 12) {
        Text("顶部显示策略").font(.subheadline.weight(.semibold))
        Picker("顶部入口", selection: Binding(get: { model.settings.displayMode.rawValue }, set: { model.settings.islandMode = $0 })) {
          ForEach(IslandDisplayMode.allCases) { Text($0.title).tag($0.rawValue) }
        }.pickerStyle(.menu)
        Picker("显示位置", selection: Binding(get: { model.settings.screenPolicy }, set: { model.settings.islandScreen = $0 })) {
          Text("跟随管理窗口").tag("follow")
          Text("主显示器").tag("main")
          ForEach(screens, id: \.id) { screen in Text(screen.name).tag(screen.id) }
          if model.settings.screenPolicy.hasPrefix("display:") && !screens.contains(where: { $0.id == model.settings.screenPolicy }) {
            Text("上次显示器（未连接，暂用主屏）").tag(model.settings.screenPolicy)
          }
        }.pickerStyle(.menu).disabled(model.settings.displayMode == .menuOnly)
        Text("仅菜单栏只隐藏顶部面板，Pi 与用量采集继续。显示器离线时安全回退，不覆盖保存的选择。修改立即预览，保存后下次启动沿用。").font(.caption).foregroundStyle(.secondary)
        Button("保存 Pi Desk 设置") { model.saveSettings() }.buttonStyle(.bordered)
      }
    }
  }
}
