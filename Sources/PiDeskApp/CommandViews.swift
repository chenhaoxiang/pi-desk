import AppKit
import PiDeskCore
import SwiftUI

struct CommandPaletteView: View {
  @EnvironmentObject var model: AppModel
  @State private var query = ""
  @State private var snapshot: [DeskCommandEntry] = []
  @State private var selectedIndex = 0
  @FocusState private var searching: Bool
  private var matches: [DeskCommandEntry] { snapshot.filter { $0.matches(query) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "command")
        TextField("搜索会话、页面或操作", text: $query).textFieldStyle(.plain).focused($searching).onSubmit(execute)
        Button("关闭") { model.modal = nil }.keyboardShortcut(.cancelAction)
      }.padding(18)
      Divider()
      commandList
      HStack { Text("↑↓ 选择 · 回车执行 · Esc 关闭"); Spacer(); Text("只查已接入状态，不读取历史正文") }
        .font(.caption).foregroundStyle(.secondary).padding(16)
    }.frame(width: 620, height: 480)
      .onAppear { snapshot = model.commandEntries(); searching = true }
      .onChange(of: query) { _, _ in selectedIndex = 0 }
      .onKeyPress(.downArrow) { move(1); return .handled }
      .onKeyPress(.upArrow) { move(-1); return .handled }
      .onExitCommand { model.modal = nil }
  }
  private var commandList: some View {
    let rows = matches
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 4) {
          if rows.isEmpty { Text("没有匹配的已接入会话或操作").foregroundStyle(.secondary).padding(30) }
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
            Button { model.performCommand(entry) } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if !entry.detail.isEmpty { Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(index == selectedIndex ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).id(entry.id)
          }
        }.padding(.horizontal, 12)
      }.onChange(of: selectedIndex) { _, index in if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) } }
    }
  }
  private func move(_ delta: Int) { guard !matches.isEmpty else { return }; selectedIndex = (selectedIndex + delta + matches.count) % matches.count }
  private func execute() { let rows = matches; if rows.indices.contains(selectedIndex) { model.performCommand(rows[selectedIndex]) } }
}

struct DraftsView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject private var assistant: DeskAssistantClient
  init(model: AppModel) { _assistant = ObservedObject(wrappedValue: model.assistant) }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack { Text("未发送草稿").font(.title3.weight(.semibold)); Spacer(); Button("关闭") { model.modal = nil }.keyboardShortcut(.cancelAction) }
      Text("草稿只留在本次 App 内存；退出时会提醒。这里不会自动发送到新的运行，也不将正文写入统计库。").font(.caption).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if model.unsentDraftCount == 0 { Text("没有未发送草稿").foregroundStyle(.secondary).padding() }
          if assistant.hasUnsentExtra {
            DeskCard {
              VStack(alignment: .leading, spacing: 10) {
                Text("AI 助手的未提交补充说明").font(.subheadline.weight(.semibold))
                Text(assistant.extra).font(.system(size: 12)).textSelection(.enabled).lineLimit(6)
                HStack {
                  Button("复制说明") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(assistant.extra, forType: .string) }
                  Spacer()
                  Button("丢弃说明", role: .destructive) { assistant.extra = "" }
                }.buttonStyle(.bordered).font(.caption)
              }
            }
          }
          ForEach(model.unsentDraftIdentities, id: \.self) { identity in DraftRow(identity: identity) }
        }
      }
    }.padding(22).frame(width: 640, height: 520)
  }
}
private struct DraftRow: View {
  let identity: Identity
  @EnvironmentObject var model: AppModel
  private var session: SessionView? {
    guard let value = model.store.sessions[identity.sessionKey], value.snapshot.identity == identity else { return nil }
    return value
  }
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 10) {
        Text(session.map { model.sessionTitle($0) } ?? "原运行已更新或未接入 · " + identity.nativeSessionId.suffix(6)).font(.subheadline.weight(.semibold))
        Text(model.drafts[identity] ?? "").font(.system(size: 12)).textSelection(.enabled).lineLimit(6)
        HStack {
          Button("复制草稿") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.drafts[identity] ?? "", forType: .string) }
          Button("查看会话详情") { model.modal = nil; model.select(identity); model.navigate(to: "会话") }.disabled(session == nil)
          Spacer()
          Button("丢弃此草稿", role: .destructive) { model.setDraft("", for: identity) }
        }.buttonStyle(.bordered).font(.caption)
      }
    }
  }
}
