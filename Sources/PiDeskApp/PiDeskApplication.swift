import AppKit
import PiDeskCore
import SwiftUI

@MainActor final class DeskDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model = AppModel()
  let island = IslandController()
  private var manager: NSWindow?
  private var managerOpen = false
  private func updateUsageInterest() {
    model.setManagerVisibility(managerOpen && manager?.isVisible == true && manager?.isMiniaturized == false && manager?.occlusionState.contains(.visible) == true && !NSApp.isHidden)
  }
  func windowDidChangeOcclusionState(_ notification: Notification) { updateUsageInterest() }
  func windowDidMiniaturize(_ notification: Notification) { updateUsageInterest() }
  func windowDidDeminiaturize(_ notification: Notification) { updateUsageInterest() }
  func windowWillClose(_ notification: Notification) { managerOpen = false; model.setManagerVisibility(false) }
  func applicationDidHide(_ notification: Notification) { updateUsageInterest() }
  func applicationDidUnhide(_ notification: Notification) { updateUsageInterest() }
  func applicationDidFinishLaunching(_ notification: Notification) {
    model.showManager = { [weak self] in self?.showManager() }
    island.start(model: model)
    if model.notificationActivationRequested { showManager() }
    else if CommandLine.arguments.contains("--show-manager") { showManager(activate: false) }
  }
  func showManager(activate: Bool = true) {
    if manager == nil {
      let narrow = model.isPreview && CommandLine.arguments.contains("--narrow-preview")
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: narrow ? 960 : 1120, height: narrow ? 620 : 760),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = model.isPreview ? "Pi Desk 合成预览" : "Pi Desk"
      window.identifier = NSUserInterfaceItemIdentifier("manager")
      window.titlebarAppearsTransparent = true
      window.minSize = NSSize(width: 960, height: 620)
      window.isReleasedWhenClosed = false
      window.delegate = self
      let content = AnyView(DeskWindow().environmentObject(model))
      window.contentView = NSHostingView(
        rootView: model.isPreview && CommandLine.arguments.contains("--light-preview")
          ? AnyView(content.preferredColorScheme(.light)) : content)
      window.center()
      manager = window
      island.attachManager(window)
    }
    managerOpen = true
    if activate {
      manager?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      manager?.orderFrontRegardless()
    }
    updateUsageInterest()
    if model.isPreview && CommandLine.arguments.contains("--narrow-preview") {
      DispatchQueue.main.async { [weak self] in
        guard let self, let window = self.manager else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 960, height: 620)), display: true)
        self.island.updateGeometry(animated: false)
      }
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showManager()
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model.requiresDraftConfirmation else { return .terminateNow }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "还有 \(model.unsentDraftCount) 份未发送草稿"
    alert.informativeText = "退出或更新不会停止 Pi，但这些草稿不会自动保存。保留草稿可继续使用 App；只有明确丢弃才退出。"
    alert.addButton(withTitle: "保留草稿，继续使用")
    alert.addButton(withTitle: "丢弃草稿并退出")
    return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
  }
  func applicationWillTerminate(_ notification: Notification) {
    model.flushViewState()
    island.stop()
    model.stop()
  }
}
@main struct PiDeskApplication: App {
  @NSApplicationDelegateAdaptor(DeskDelegate.self) private var delegate
  var body: some Scene {
    MenuBarExtra {
      MenuContents().environmentObject(delegate.model)
    } label: {
      MenuLabel().environmentObject(delegate.model)
    }.menuBarExtraStyle(.window)
    Settings { ScrollView { SettingsPage().environmentObject(delegate.model).padding(20) }.frame(width: 640, height: 560) }
      .commands {
        CommandGroup(after: .appInfo) {
          Button("打开管理窗口") { delegate.showManager() }.keyboardShortcut("0", modifiers: .command)
          Button("展开顶部速览") { delegate.island.expand() }.disabled(delegate.model.settings.displayMode == .menuOnly)
          Button("命令面板") { delegate.model.modal = .commands }.keyboardShortcut("k", modifiers: .command)
          Button("未发送草稿") { delegate.model.modal = .drafts }
        }
        CommandMenu("导航") {
          Button("会话") { delegate.model.navigate(to: "会话") }.keyboardShortcut("1", modifiers: .command)
          Button("Token") { delegate.model.navigate(to: "Token") }.keyboardShortcut("2", modifiers: .command)
          Button("重要事项") { delegate.model.navigate(to: "重要事项") }.keyboardShortcut("3", modifiers: .command)
          Button("接入健康") { delegate.model.navigate(to: "接入健康") }.keyboardShortcut("4", modifiers: .command)
          Button("AI助手") { delegate.model.navigate(to: "AI助手") }.keyboardShortcut("5", modifiers: .command)
          Divider()
          Button("搜索会话") { delegate.model.focusSessionSearch() }.keyboardShortcut("f", modifiers: .command)
          Button("下一个需关注会话") { delegate.model.nextAttentionSession() }.keyboardShortcut("n", modifiers: [.command, .option])
        }
      }
  }
}
struct MenuLabel: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Label(
      "已确认执行 \(model.activeCount)",
      systemImage: model.inputCount > 0 ? "questionmark.circle" : "circle.hexagongrid")
  }
}
struct MenuContents: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        PiMark()
        Text("Pi Desk").font(.headline)
        Spacer()
        if model.isPreview { PreviewBadge() }
      }
      Text("已接入 \(model.connectedCount) · 已确认执行 \(model.activeCount) · \(model.inputCount) 个需要输入").font(.subheadline)
        .foregroundStyle(.secondary)
      if model.unknownExecutionCount > 0 {
        Text("执行状态待核 \(model.unknownExecutionCount)（不代表本机全部Pi）").font(.caption).foregroundStyle(.orange)
      }
      Button("展开顶部速览") { model.showIsland() }.disabled(model.settings.displayMode == .menuOnly)
      Button("打开管理窗口") { model.showManager() }
      Divider()
      Toggle("本次静音提醒", isOn: $model.muted)
      Button("退出 Pi Desk（Pi 继续）") {
        model.stop()
        NSApp.terminate(nil)
      }
    }.padding(18).frame(width: 300)
  }
}
struct DeskWindow: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  let pages = DeskNavigation.pages
  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 9) {
          PiMark(size: 25)
          Text("Pi Desk").font(.system(size: 18, weight: .semibold))
          Spacer()
        }.padding(.horizontal, 17).padding(.top, 20).padding(.bottom, 20)
        List(pages, id: \.self, selection: $model.page) { page in
          HStack {
            Label(page, systemImage: icon(page))
            Spacer()
            if page == "会话" { Text("\(model.visibleSessions.count)").foregroundStyle(.secondary) }
            if page == "重要事项" && model.attentionCount > 0 {
              Text("\(model.attentionCount)").foregroundStyle(.orange)
            }
          }.padding(.vertical, 5).tag(page)
        }.listStyle(.sidebar)
        Label("Pi 继续独立运行", systemImage: "checkmark.shield").font(.system(size: 10)).foregroundStyle(
          .secondary
        ).padding(16)
      }.navigationSplitViewColumnWidth(175)
    } detail: {
      VStack(spacing: 0) {
        header
        Divider()
        if let notice = model.navigationNotice {
          HStack(alignment: .top) {
            Label(notice, systemImage: "info.circle").font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { model.navigationNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("关闭导航提示")
          }.padding(14).foregroundStyle(.secondary)
          Divider()
        }
        if model.page == "AI助手" {
          AssistantPage(model: model)
        } else if model.page == "接入健康" {
          HealthPage()
        } else if model.page == "设置" {
          ScrollView { SettingsPage().padding(24) }
        } else if model.page == "Token" {
          AggregateTokenPage()
        } else if model.page == "重要事项" {
          AttentionPage().padding(24)
        } else {
          HSplitView {
            SessionList().frame(minWidth: 250, idealWidth: 285, maxWidth: 335)
            ScrollView { SessionDetail().padding(22) }.id(model.current?.snapshot.identity).frame(minWidth: 430)
          }
        }
      }
    }.background(Color(nsColor: .windowBackgroundColor))
      .onChange(of: model.page) { _, _ in model.persistViewState() }
      .sheet(item: $model.modal) { modal in
        switch modal {
        case .commands: CommandPaletteView().environmentObject(model)
        case .drafts: DraftsView(model: model).environmentObject(model)
        case .groups: WorkGroupsView().environmentObject(model)
        }
      }
  }
  var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 5) {
        Text(model.page == "会话" ? "工作概览" : (model.page == "Token" ? "用量总览" : model.page)).font(.system(size: model.page == "Token" ? 19 : 21, weight: .semibold))
        if model.page != "Token" { Text("\(model.connectedCount) 个已接入 · \(model.attentionCount) 个需关注").font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      if model.isPreview { PreviewBadge() }
      if model.diagnostic.hasPrefix("连接不可用") {
        Label("本机连接暂不可用", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(
          .orange)
      }
      Label("运行中 \(model.activeCount)", systemImage: "circle.fill").font(.system(size: 11))
        .foregroundStyle(StatusTone.green.ink(dark: scheme == .dark))
      if model.unknownExecutionCount > 0 {
        Label("\(model.unknownExecutionCount) 状态待核", systemImage: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
      }
      if model.unreadResultCount > 0 {
        Label("\(model.unreadResultCount) 新变化", systemImage: "circle.fill").font(.system(size: 11)).foregroundStyle(.blue)
      }
      if model.inputCount > 0 {
        Label("\(model.inputCount) 需输入", systemImage: "questionmark.circle.fill").font(
          .system(size: 11)
        ).foregroundStyle(StatusTone.amber.ink(dark: scheme == .dark))
      }
      if model.page != "Token" {
        Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).help("刷新选定会话").accessibilityLabel("刷新当前页面")
      }
    }.padding(.horizontal, 25).padding(.vertical, model.page == "Token" ? 12 : 20)
  }
  func icon(_ p: String) -> String {
    [
      "会话": "rectangle.stack", "Token": "chart.bar", "重要事项": "bell", "设置": "gearshape",
      "AI助手": "sparkles", "接入健康": "heart.text.square",
    ][p] ?? "circle"
  }
}
struct SessionList: View {
  @EnvironmentObject var model: AppModel
  @FocusState private var searchFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("我的会话").font(.subheadline.weight(.semibold))
        Spacer()
        Text("显示 \(model.visibleSessions.count) / 已接入 \(model.sessions.count)").font(.caption2).foregroundStyle(.secondary)
      }.padding(17)
      VStack(spacing: 10) {
        TextField("搜索会话、项目或模型", text: $model.search).textFieldStyle(.roundedBorder).focused($searchFocused).accessibilityLabel("搜索已接入会话")
        HStack {
          Picker("状态", selection: $model.sessionFilter) {
            ForEach(AppModel.sessionFilters, id: \.self) { Text($0).tag($0) }
          }.pickerStyle(.menu).labelsHidden().frame(width: 96).accessibilityLabel("按状态筛选会话")
          Menu {
            Button("全部分组") { model.groupFilter = ""; model.persistViewState() }
            Button("未分组") { model.groupFilter = "__none__"; model.persistViewState() }
            ForEach(model.workGroups, id: \.self) { name in Button(name) { model.groupFilter = name; model.persistViewState() } }
            Divider()
            Button("管理工作分组") { model.modal = .groups }
          } label: { Label(model.groupFilterTitle, systemImage: "folder").lineLimit(1) }
            .menuStyle(.borderlessButton).help(model.groupFilterTitle).accessibilityLabel("按工作分组筛选，当前" + model.groupFilterTitle)
          Spacer(minLength: 0)
          Button { model.nextAttentionSession() } label: { Image(systemName: "arrow.right.circle") }
            .buttonStyle(.borderless).disabled(model.attentionCount == 0).help("下一个需关注会话")
            .accessibilityLabel("下一个需关注会话")
        }
        if !model.hiddenSessions.isEmpty { Button("显示已隐藏卡片（不改变运行）") { model.clearHiddenSessions() }.font(.caption2) }
      }.padding(.horizontal, 13).padding(.bottom, 12)
      ScrollView {
        LazyVStack(spacing: 9) {
          if model.sessions.isEmpty {
            ContentUnavailableView(
              "尚无已接入会话", systemImage: "rectangle.stack",
              description: Text("新 Pi 自然加载桥接后即可显示，不扫描历史。"))
          }
          if model.visibleSessions.isEmpty && !model.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text(model.sessionFilter == "在线" && model.search.isEmpty ? "当前没有在线会话；断连记录可在“断连”或“全部”查看。" : "没有匹配的会话；可调整搜索或筛选。")
              Button("清除搜索与筛选") { model.search = ""; model.sessionFilter = "在线"; model.groupFilter = "" }.buttonStyle(.borderless)
              Text("这里只隐藏显示，不会停止或删除原Pi工作。").foregroundStyle(.secondary)
            }.font(.caption).padding()
          }
          ForEach(model.visibleSessions, id: \.snapshot.identity) { s in
            Button {
              model.select(s.snapshot.identity)
            } label: {
              SessionCard(
                session: s, selected: model.selected == s.snapshot.identity.sessionKey,
                onSelect: { model.select(s.snapshot.identity) })
            }.buttonStyle(.plain).focusable().accessibilityLabel(
              model.sessionTitle(s) + " · " + Presentation.status(s).title)
              .contextMenu {
                Button(model.isPinned(s.snapshot.identity) ? "取消置顶" : "置顶此会话") { model.togglePin(s.snapshot.identity) }
                if s.connection != .connected { Button("仅隐藏卡片（不停止工作）") { model.hideDisconnected(s.snapshot.identity) } }
              }
          }
        }.padding(.horizontal, 12).padding(.bottom, 16)
          .transaction { transaction in transaction.animation = nil }
      }
    }.background(Color(nsColor: .windowBackgroundColor))
      .onAppear { if model.searchFocusRequest > 0 { searchFocused = true; model.searchFocusRequest = 0 } }
      .onChange(of: model.searchFocusRequest) { _, request in if request > 0 { searchFocused = true; model.searchFocusRequest = 0 } }
  }
}
struct SessionDetail: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    if let session = model.current {
      let snap = session.snapshot
      VStack(alignment: .leading, spacing: 21) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 7) {
            Text(model.sessionTitle(session)).font(.system(size: 23, weight: .semibold)).fixedSize(
              horizontal: false, vertical: true)
            Text(
              [Presentation.project(snap), snap.display.branch, Presentation.shortModel(snap)]
                .compactMap { $0 }.joined(separator: " · ")
            ).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 14) {
              SessionIdentityControls(session: session)
              WorkGroupControl(session: session)
            }.id(snap.identity)
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 7) {
            StatusPill(status: Presentation.status(session))
            Label(Presentation.connection(session.connection), systemImage: Presentation.connectionStatus(session).symbol)
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if Presentation.needsExecutionReview(session) {
          Label("执行状态待核，详见诊断", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
        }
        SessionActions(session: session).id(snap.identity)
        if let note = model.sessionNotes[snap.identity] {
          Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !model.canOpenOriginal(identity: snap.identity) {
          Text("原会话暂不可定位，原因见下方定位诊断。").font(.caption).foregroundStyle(.secondary)
        }
        if Presentation.needsInput(session) {
          DeskCard {
            VStack(alignment: .leading, spacing: 9) {
              Label("等待你输入", systemImage: "questionmark.circle.fill").font(.subheadline.weight(.semibold))
                .foregroundStyle(StatusTone.amber.ink(dark: scheme == .dark))
              Text(SessionExperience.timing(session)).font(.caption).foregroundStyle(.secondary)
              Text("请到原会话处理。已读只改变提醒表现，不会代答。").font(.caption).foregroundStyle(.secondary)
              let read = snap.inputs.allSatisfy { model.isRead($0, session: snap.identity) }
              Button(read ? "已读 · 仍待输入" : "标为已读") {
                for input in snap.inputs { model.markRead(input, session: snap.identity) }
              }.buttonStyle(.borderless).disabled(read)
            }
          }
        }
        if !Presentation.needsInput(session) {
        DeskCard {
          VStack(alignment: .leading, spacing: 10) {
            HStack { Text("当前活动").font(.subheadline.weight(.semibold)); Spacer(); Text(SessionExperience.timing(session)).font(.caption).foregroundStyle(.secondary) }
            Label(Presentation.activity(session), systemImage: snap.tools.isEmpty ? "circle.dotted" : "wrench.and.screwdriver")
              .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            if let started = snap.activity?.turnStartedAt {
              Text("回合开始 " + Date(timeIntervalSince1970: started / 1000).formatted()).font(.caption).foregroundStyle(.secondary)
            }
            if let ended = snap.activity?.turnEndedAt {
              Text("回合结束 " + Date(timeIntervalSince1970: ended / 1000).formatted() + " · 业务结果请查看原会话").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        }
        OperationsSection(identity: snap.identity)
        DisclosureGroup("子任务 \(snap.runs.count) · " + Presentation.coverage(snap.childCoverage)) {
          RunsSection(session: session)
        }.font(.caption)
        DisclosureGroup("已有计划 \(snap.schedules.count) · 按原系统管理") {
          SchedulesSection(session: session)
        }.font(.caption)
        DisclosureGroup("会话用量 · " + Presentation.usage(snap).scope) {
          DeskCard { UsageTiles(snapshot: snap) }
        }.font(.caption)
        DisclosureGroup("原会话定位诊断") {
          VStack(alignment: .leading, spacing: 9) {
            Text(model.routeNotes[snap.identity] ?? "没有可用的精确路由；不会按名称猜测窗口或启动第二个Pi。")
            ViewThatFits(in: .horizontal) {
              HStack { routeButtons(session) }
              VStack(alignment: .leading, spacing: 8) { routeButtons(session) }
            }
          }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }.font(.caption)
        SessionDiagnostics(session: session)
      }.onAppear { model.markVisibleResultViewed(snap.identity) }
        .onChange(of: snap.activity?.turnEndSequence) { _, _ in model.markVisibleResultViewed(snap.identity) }
    } else {
      ContentUnavailableView(
        "选择一个会话", systemImage: "rectangle.stack", description: Text("查看状态、定位现场，或向原 Pi 追加要求。"))
    }
  }
  @ViewBuilder private func routeButtons(_ session: SessionView) -> some View {
    Button("刷新定位") { model.refreshOriginalRoute(identity: session.snapshot.identity) }.disabled(session.connection != .connected)
    Button("检查终端权限") { model.checkOriginalRoutePermission(identity: session.snapshot.identity) }.disabled(session.connection != .connected)
    Button("请求终端定位权限") { model.checkOriginalRoutePermission(identity: session.snapshot.identity, requestConsent: true) }.disabled(session.connection != .connected)
  }
}
struct RunsSection: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  @State private var texts: [String: String] = [:]
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("子任务 \(session.snapshot.runs.count)").font(.subheadline.weight(.semibold))
          Spacer()
          Button("刷新子任务") { model.refresh(identity: session.snapshot.identity) }.font(.caption).disabled(session.connection != .connected)
        }
        Text("来源：当前选定会话 · " + Presentation.coverage(session.snapshot.childCoverage) + " · " + Presentation.connection(session.connection)).font(.caption).foregroundStyle(.secondary)
        if let time = model.sectionRefreshRequestedAt[session.snapshot.identity] { Text("已请求刷新 " + time.formatted(date: .omitted, time: .standard) + "；受理不等于原系统已返回。").font(.caption2).foregroundStyle(.secondary) }
        if session.snapshot.runs.isEmpty {
          Text("暂无可用的子任务信息，不推断它们已经全部结束。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(session.snapshot.runs) { r in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(r.agent ?? "子任务").font(.subheadline.weight(.medium))
              Spacer()
              Text(Presentation.runState(r.state)).font(.caption).foregroundStyle(.secondary)
            }
            if let recovery = r.recovery {
              Text("恢复：" + recovery.action + " · " + recovery.reason)
                .font(.caption2)
                .foregroundStyle(recovery.state == "unknown" ? .orange : .secondary)
            }
            if let runId = r.runId {
              let target = Target(owner: r.owner, runId: runId)
              Button("刷新此运行状态") { model.refresh(identity: session.snapshot.identity, runId: r.parentRunId ?? runId) }.font(.caption).disabled(session.connection != .connected)
              if session.connection == .connected && (r.actions.contains(.steer) || r.actions.contains(.resume)) {
                TextField(
                  "向此子任务递送的要求",
                  text: Binding(get: { texts[r.key] ?? "" }, set: { texts[r.key] = $0 })
                ).textFieldStyle(.roundedBorder)
              }
              HStack {
                if r.actions.contains(.steer) {
                  Button("纠偏") {
                    model.action(
                      .steer, target: target,
                      parameters: Parameters(text: texts[r.key], mode: "steer"),
                      identity: session.snapshot.identity)
                  }.disabled((texts[r.key] ?? "").isEmpty)
                }
                if r.actions.contains(.resume) {
                  Button("恢复原运行") {
                    model.action(
                      .resume, target: target, parameters: Parameters(text: texts[r.key]),
                      identity: session.snapshot.identity)
                  }.disabled((texts[r.key] ?? "").isEmpty)
                }
                if r.actions.contains(.stop) {
                  Menu("更多") {
                    Button("请求停止子任务", role: .destructive) {
                      model.action(.stop, target: target, identity: session.snapshot.identity)
                    }
                  }
                }
              }.buttonStyle(.bordered).disabled(session.connection != .connected)
            }
            DisclosureGroup("运行诊断") {
              Text(r.runId ?? "此对象仅作展示，没有控制ID").font(.caption.monospaced()).textSelection(.enabled)
              Text("原始状态：" + r.state + " · 终态证明：" + (r.terminalProof ?? "未提供")).font(.caption)
            }.font(.caption2).foregroundStyle(.secondary)
          }.padding(.vertical, 7)
        }
        Text("停止受理不等于进程终态；恢复资格仍由原系统验证。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct SchedulesSection: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 13) {
        HStack {
          Text("已有计划 \(session.snapshot.schedules.count)").font(.subheadline.weight(.semibold))
          Spacer()
          Button("刷新计划") { model.refresh(identity: session.snapshot.identity) }.font(.caption).disabled(session.connection != .connected)
        }
        Text("暂停只影响未来触发，不撤销当前运行；来源与控制按owner分开。" + Presentation.connection(session.connection)).font(.caption).foregroundStyle(.secondary)
        if let time = model.sectionRefreshRequestedAt[session.snapshot.identity] { Text("已请求刷新 " + time.formatted(date: .omitted, time: .standard) + "；返回状态仍以原系统为准。").font(.caption2).foregroundStyle(.secondary) }
        if session.snapshot.schedules.isEmpty {
          Text("暂无可在线管理的计划信息，可回原系统查看；不直接修改其存储。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(session.snapshot.schedules) { s in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(s.name).font(.subheadline.weight(.medium))
              Spacer()
              Text(Presentation.runState(s.state)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
              ForEach(s.actions, id: \.rawValue) { a in
                Button(Presentation.action(a)) {
                  model.action(
                    a, target: Target(owner: s.owner, scheduleId: s.scheduleId),
                    identity: session.snapshot.identity)
                }.disabled(session.connection != .connected)
              }
            }.buttonStyle(.bordered)
            Text(s.owner == "subagents" ? "子任务计划（Subagents）" : "定时提示（Schedule）").font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Text("暂停只影响未来触发，不撤销当前运行。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct OperationsSection: View {
  let identity: Identity
  @EnvironmentObject var model: AppModel
  var body: some View {
    let rows = model.store.requests.values.filter { $0.identity == identity }.sorted {
      $0.submittedAt > $1.submittedAt
    }.prefix(5)
    if !rows.isEmpty {
      DeskCard {
        VStack(alignment: .leading, spacing: 10) {
          Text("最近的操作").font(.subheadline.weight(.medium))
          ForEach(Array(rows)) { r in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(Presentation.action(r.action))
                Text(Date(timeIntervalSince1970: r.submittedAt / 1000).formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                Spacer()
                Text(Presentation.receipt(r.status)).foregroundStyle(
                  r.status == "unknown" ? .orange : .secondary)
              }.font(.caption)
              DisclosureGroup("回执诊断") {
                Text(r.code + (r.ownerRef.map { " · " + $0 } ?? "")).font(.caption2.monospaced())
                  .textSelection(.enabled)
              }.font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }
}
struct TokenPage: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 17) {
        HStack {
          VStack(alignment: .leading, spacing: 7) {
            Text("看清用量，也看清统计边界").font(.title3.weight(.semibold))
            Text("这里只看已接入范围，不做历史或全账户账单。").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("刷新选定会话") { model.refresh(usage: true) }.buttonStyle(.bordered).disabled(
            model.current?.connection != .connected)
        }
        ForEach(model.sessions, id: \.snapshot.identity) { s in
          DeskCard {
            VStack(alignment: .leading, spacing: 16) {
              HStack {
                Text(s.snapshot.display.name).font(.headline)
                Spacer()
                Text(Presentation.connection(s.connection)).font(.caption).foregroundStyle(
                  .secondary)
              }
              UsageTiles(snapshot: s.snapshot)
              Text("上下文占用：" + Presentation.count(s.snapshot.contextTokens) + "（不是已消耗用量）").font(
                .caption
              ).foregroundStyle(.secondary)
              SessionDiagnostics(session: s)
            }
          }
        }
        if model.sessions.isEmpty {
          ContentUnavailableView(
            "还没有用量信息", systemImage: "chart.bar", description: Text("已接入会话结算后会显示；未知不会填成零。"))
        }
      }
    }
  }
}
struct AttentionPage: View {
  @EnvironmentObject var model: AppModel
  private var inputSessions: [SessionView] { model.attentionSessions.filter { Presentation.needsInput($0) } }
  private var failedSessions: [SessionView] { model.attentionSessions.filter { !Presentation.needsInput($0) && Presentation.executionState($0) == .failed } }
  private var resultSessions: [SessionView] { model.attentionSessions.filter { !Presentation.needsInput($0) && Presentation.executionState($0) != .failed && model.hasUnreadResult($0) } }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Toggle("本次静音提醒", isOn: $model.muted).font(.caption)
          .help("只改变提醒表现，不回答或取消原问题")
        AttentionSection(title: "等待你输入", sessions: inputSessions)
        AttentionSection(title: "本轮出现异常", sessions: failedSessions)
        AttentionSection(title: "本轮结束，有新变化", sessions: resultSessions)
        if model.attentionCount == 0 {
          ContentUnavailableView("当前没有需关注事项", systemImage: "checkmark.circle", description: Text("会话会继续独立运行。"))
        }
        Text("已读不回答问题；本轮结束不代表业务验收通过。").font(.caption).foregroundStyle(.secondary)
        AttentionEvidenceSection(sessions: model.sessions.filter { !$0.snapshot.evidence.isEmpty })
      }
    }
  }
}
private struct AttentionSection: View {
  let title: String
  let sessions: [SessionView]
  var body: some View {
    if !sessions.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        Text(title + " · \(sessions.count)").font(.subheadline.weight(.semibold))
        ForEach(sessions, id: \.snapshot.identity) { session in AttentionSessionCard(session: session) }
      }
    }
  }
}
private struct AttentionSessionCard: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  private var inputRead: Bool { session.snapshot.inputs.allSatisfy { model.isRead($0, session: session.snapshot.identity) } }
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack { Text(model.sessionTitle(session)).font(.headline).lineLimit(2); Spacer(); StatusPill(status: Presentation.status(session)) }
        Text(Presentation.activity(session)).font(.subheadline)
        Text(SessionExperience.timing(session)).font(.caption).foregroundStyle(.secondary)
        actions
      }
    }
  }
  private var actions: some View {
    HStack {
      Button("查看详情") { model.select(session.snapshot.identity); model.navigate(to: "会话") }
      Button(model.originalRouteLabel(identity: session.snapshot.identity)) { model.openOriginal(identity: session.snapshot.identity) }
        .disabled(!model.canOpenOriginal(identity: session.snapshot.identity))
      if Presentation.needsInput(session) {
        Button(inputRead ? "已读 · 仍待输入" : "标为已读") {
          for input in session.snapshot.inputs { model.markRead(input, session: session.snapshot.identity) }
        }.disabled(inputRead)
      } else if model.hasUnreadResult(session) {
        Button("标为已查看") { model.markResultViewed(session.snapshot.identity) }
      }
    }.buttonStyle(.bordered).font(.caption)
  }
}
private struct AttentionEvidenceSection: View {
  let sessions: [SessionView]
  var body: some View {
    DisclosureGroup("治理与验证来源") {
      ForEach(sessions, id: \.snapshot.identity) { session in AttentionEvidenceRow(session: session) }
      if sessions.isEmpty { Text("尚未配置治理/CI来源").font(.caption).foregroundStyle(.secondary) }
    }.font(.caption)
  }
}
private struct AttentionEvidenceRow: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  private func title(_ evidence: Evidence) -> String {
    let status = Presentation.runState(evidence.status)
    let binding = evidence.nature == "advice" ? "建议" : "当前版本绑定未核验"
    return "\(evidence.category) · 原系统报告 \(status) · \(binding)"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(model.sessionTitle(session)).font(.caption.weight(.medium))
      ForEach(session.snapshot.evidence) { evidence in
        Text(verbatim: title(evidence)).font(.caption)
        Text(evidence.source + " · " + (evidence.head ?? "版本未知")).font(.caption2.monospaced()).foregroundStyle(.secondary)
      }
    }
  }
}
struct SettingsPage: View {
  @EnvironmentObject var model: AppModel
  @State private var section = "Pi Desk"
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Picker("设置分类", selection: $section) {
        ForEach(["Pi Desk", "Pi 原生设置", "高级连接"], id: \.self) { Text($0).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("设置分类")
      if section == "Pi Desk" {
      DisplayPreferencesView()
      DeskCard {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            PiMark(size: 28)
            VStack(alignment: .leading, spacing: 5) {
              Text("Pi Desk").font(.title3.weight(.semibold))
              Text("\(BuildIdentity.version) · 本机版本 \(BuildIdentity.build)").font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isPreview { PreviewBadge() }
          }
          Text("顶部速览让你随时看到进展；退出界面，Pi 仍独立运行。").font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("展开顶部速览") { model.showIsland() }.buttonStyle(.bordered).disabled(model.settings.displayMode == .menuOnly)
            Button("配置 AI 助手") { model.navigate(to: "AI助手") }.buttonStyle(.bordered)
          }
        }
      }
      DeskCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("提醒表现").font(.subheadline.weight(.semibold))
          Toggle("使用系统已授权的通知", isOn: $model.settings.notifications)
          Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("开启系统通知") { model.enableNotifications() }.disabled(model.isPreview || model.requestingNotifications)
            Button("检查系统通知状态") { model.checkNotificationStatus() }
            Button("发送测试通知") { model.sendTestNotification() }.disabled(!model.notificationsAuthorized || model.isPreview)
          }.font(.caption)
          Text("仅主动点击开启时向系统申请许可；是否允许由你在系统提示中决定。拒绝或发送失败不影响原Pi通知与自动化。").font(.caption).foregroundStyle(.secondary)
          Button("保存 Pi Desk 设置") { model.saveSettings() }.buttonStyle(.bordered)
        }
      }
      }
      if section == "Pi 原生设置" {
        Text("这里修改的是 Pi 用户默认设置，下次会话生效；当前会话和项目覆盖不变。").font(.caption).foregroundStyle(.secondary)
        PiSettingsCard(projectCwd: model.current?.snapshot.display.cwd ?? model.sessions.first?.snapshot.display.cwd)
      }
      if section == "高级连接" {
        DeskCard {
          VStack(alignment: .leading, spacing: 12) {
            Text("可选管理入口").font(.subheadline.weight(.semibold))
            TextField("Herdr 可执行文件绝对路径（可选）", text: $model.settings.herdrExecutable).textFieldStyle(.roundedBorder)
            TextField("精确 HTTPS 管理页（可选）", text: $model.settings.managementURL).textFieldStyle(.roundedBorder)
            Button("打开已配置管理页") { model.openManagement() }.disabled(LinkPolicy.exactHTTPS(model.settings.managementURL) == nil)
            Text("不使用 Herdr 也可以查看 Pi 状态；精确路由不可用时不会跳到其他会话。").font(.caption).foregroundStyle(.secondary)
            Button("保存 Pi Desk 设置") { model.saveSettings() }.buttonStyle(.bordered)
          }
        }
      DisclosureGroup("诊断信息与版本来源") {
        VStack(alignment: .leading, spacing: 8) {
          Text(BuildIdentity.label).font(.caption.monospaced()).textSelection(.enabled)
          Text("源码：" + BuildIdentity.source).font(.caption.monospaced()).textSelection(.enabled)
          Text(model.socketPath).font(.caption.monospaced()).textSelection(.enabled)
          Text(model.diagnostic).font(.caption)
          Text("本机 ad-hoc 构建，未公证、未对外发行；不强制重载已有业务会话。").font(.caption).foregroundStyle(.secondary)
        }
      }.font(.caption)
      }
      if !model.actionNote.isEmpty { Text(model.actionNote).font(.caption).foregroundStyle(.secondary) }
    }.onAppear {
      guard model.isPreview, let index = CommandLine.arguments.firstIndex(of: "--visual-settings-section"),
        index + 1 < CommandLine.arguments.count else { return }
      let requested = CommandLine.arguments[index + 1]
      if ["Pi Desk", "Pi 原生设置", "高级连接"].contains(requested) { section = requested }
    }
  }
}
