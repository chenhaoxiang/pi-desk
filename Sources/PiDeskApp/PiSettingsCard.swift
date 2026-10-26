import SwiftUI

struct PiSettingsCard: View {
  @EnvironmentObject var model: AppModel
  let projectCwd: String?
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Pi 原生用户设置").font(.subheadline.weight(.semibold))
          Spacer()
          Button("刷新原文件") { model.reloadPiSettings(projectCwd: projectCwd) }.disabled(model.piSettingsLoading || model.isPreview)
        }
        Text("只读/编辑 canonical user settings.json；不创建 Pi Desk 配置副本。保存只影响下次会话，不自动重载当前Pi。")
          .font(.caption).foregroundStyle(.secondary)
        if model.isPreview {
          Text("合成预览：未读取真实设置，也不会写入真实文件。").font(.caption).foregroundStyle(.orange)
        } else if let snapshot = model.piSettingsSnapshot {
          Text(snapshot.path).font(.caption.monospaced()).textSelection(.enabled)
          ForEach(PiSettingField.fields) { field in
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text(field.title).frame(width: 125, alignment: .leading)
                Picker(field.title, selection: Binding(get: { model.piSettingsSelections[field.key] ?? PiSettingsStore.unset }, set: { model.piSettingsSelections[field.key] = $0 })) {
                  Text("原生默认值").tag(PiSettingsStore.unset)
                  if let raw = snapshot.values[field.key], !field.choices.contains(raw) { Text("当前其他值（保留）").tag("__keep__") }
                  ForEach(field.choices, id: \.self) { value in Text(value).tag(value) }
                }.labelsHidden().frame(maxWidth: 250)
                Spacer(minLength: 0)
              }
              Text(field.note).font(.caption2).foregroundStyle(.secondary)
              if snapshot.projectValues[field.key] != nil {
                Text("当前项目有此项覆盖（只读）；本次保存只改用户层原文件。")
                  .font(.caption2).foregroundStyle(.orange)
              }
            }
          }
          HStack {
            Button("保存到原Pi用户设置") { model.savePiSettings() }
              .disabled(model.piSettingsLoading || model.piSettingsChanges.isEmpty)
            if let path = snapshot.projectPath { Text("项目覆盖只读：" + path).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            if let issue = snapshot.projectIssue { Text("项目覆盖读取异常：" + issue).font(.caption2).foregroundStyle(.orange) }
          }
        } else if !model.piSettingsLoading {
          Text("尚未读取或尚未创建 canonical 用户设置文件；当前只读。点击刷新可重试。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(model.piSettingsLoading ? "正在读取/保存原文件…" : model.piSettingsNote).font(.caption).foregroundStyle(.secondary)
        Text("未纳入：模型/工具、auth、models、MCP、资源包、代理、信任与权限设置。冲突、锁占用、坏JSON或不安全权限时不写入。")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }.onAppear { model.reloadPiSettings(projectCwd: projectCwd) }
      .onChange(of: projectCwd) { _, _ in model.reloadPiSettings(projectCwd: projectCwd) }
  }
}
