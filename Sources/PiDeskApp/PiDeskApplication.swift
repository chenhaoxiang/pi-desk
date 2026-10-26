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
    if CommandLine.arguments.contains("--show-manager") { showManager(activate: false) }
  }
  func showManager(activate: Bool = true) {
    if manager == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
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
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showManager()
    return true
  }
  func applicationWillTerminate(_ notification: Notification) {
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
    Settings { SettingsPage().environmentObject(delegate.model).frame(width: 600).padding(20) }
      .commands {
        CommandGroup(after: .appInfo) {
          Button("打开管理窗口") { delegate.showManager() }.keyboardShortcut("0", modifiers: .command)
          Button("展开顶部速览") { delegate.island.expand() }
        }
      }
  }
}
struct MenuLabel: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Label(
      "Pi \(model.activeCount)",
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
      Text("\(model.activeCount) 个运行中 · \(model.inputCount) 个需要输入").font(.subheadline)
        .foregroundStyle(.secondary)
      Button("展开顶部速览") { model.showIsland() }
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
  let pages = ["会话", "子任务", "计划", "Token", "重要事项", "设置"]
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
            if page == "重要事项" && model.inputCount > 0 {
              Text("\(model.inputCount)").foregroundStyle(.orange)
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
        if model.page == "设置" {
          ScrollView { SettingsPage().padding(24) }
        } else if model.page == "Token" {
          AggregateTokenPage()
        } else if model.page == "重要事项" {
          AttentionPage().padding(24)
        } else {
          HSplitView {
            SessionList().frame(minWidth: 250, idealWidth: 285, maxWidth: 335)
            ScrollView { SessionDetail().padding(25) }.frame(minWidth: 430)
          }
        }
      }
    }.background(Color(nsColor: .windowBackgroundColor))
  }
  var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 5) {
        Text(model.page == "会话" ? "工作概览" : (model.page == "Token" ? "用量总览" : model.page)).font(.system(size: model.page == "Token" ? 19 : 21, weight: .semibold))
        if model.page != "Token" { Text("查看正在发生的事，不改变原来的推进方式").font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      if model.isPreview { PreviewBadge() }
      if model.diagnostic.hasPrefix("连接不可用") {
        Label("本机连接暂不可用", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(
          .orange)
      }
      Label("\(model.activeCount) 运行中", systemImage: "circle.fill").font(.system(size: 11))
        .foregroundStyle(StatusTone.green.ink(dark: scheme == .dark))
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
      "会话": "rectangle.stack", "子任务": "point.3.connected.trianglepath.dotted", "计划": "calendar",
      "Token": "chart.bar", "重要事项": "bell", "设置": "gearshape",
    ][p] ?? "circle"
  }
}
struct SessionList: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("我的会话").font(.subheadline.weight(.semibold))
        Spacer()
        Text("显示 \(model.visibleSessions.count) / 共 \(model.sessions.count)").font(.caption2).foregroundStyle(.secondary)
      }.padding(17)
      VStack(spacing: 10) {
        TextField("搜索会话、项目或模型", text: $model.search).textFieldStyle(.roundedBorder).accessibilityLabel("搜索已接入会话")
        Picker("状态筛选", selection: $model.sessionFilter) {
          ForEach(["在线", "全部", "运行中", "需输入", "断连"], id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("按状态筛选会话")
        if !model.hiddenSessions.isEmpty { Button("显示已隐藏卡片（不改变运行）") { model.hiddenSessions.removeAll() }.font(.caption2) }
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
              Button("清除搜索与筛选") { model.search = ""; model.sessionFilter = "在线" }.buttonStyle(.borderless)
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
              s.snapshot.display.name + " · " + Presentation.status(s).title)
              .contextMenu {
                if s.connection != .connected { Button("仅隐藏卡片（不停止工作）") { model.hideDisconnected(s.snapshot.identity) } }
              }
          }
        }.padding(.horizontal, 12).padding(.bottom, 16)
      }
    }.background(Color(nsColor: .windowBackgroundColor))
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
            Text(snap.display.name).font(.system(size: 25, weight: .semibold)).fixedSize(
              horizontal: false, vertical: true)
            Text(
              [Presentation.project(snap), snap.display.branch, Presentation.shortModel(snap)]
                .compactMap { $0 }.joined(separator: " · ")
            ).font(.system(size: 12)).foregroundStyle(.secondary)
          }
          Spacer()
          StatusPill(status: Presentation.status(session))
        }
        SessionActions(session: session).id(snap.identity)
        if !snap.inputs.isEmpty {
          DeskCard {
            VStack(alignment: .leading, spacing: 9) {
              Label("原会话需要输入", systemImage: "questionmark.circle.fill").font(
                .subheadline.weight(.semibold)
              ).foregroundStyle(StatusTone.amber.ink(dark: scheme == .dark))
              Text("请在原会话处理；已读和关闭提醒不会代答，也不会改变执行。").font(.caption).foregroundStyle(.secondary)
              HStack {
                Button("打开原会话") { model.openOriginal(identity: snap.identity) }.buttonStyle(
                  .bordered)
                ForEach(snap.inputs.prefix(1)) { input in
                  Button("标为已读") { model.markRead(input, session: snap.identity) }.buttonStyle(
                    .borderless)
                }
              }
            }
          }
        }
        HStack(alignment: .top, spacing: 12) {
          DeskCard {
            VStack(alignment: .leading, spacing: 8) {
              Text("当前活动").font(.caption).foregroundStyle(.secondary)
              Label(
                Presentation.activity(session),
                systemImage: snap.tools.isEmpty ? "circle.dotted" : "wrench.and.screwdriver"
              ).font(.system(size: 13, weight: .medium)).fixedSize(
                horizontal: false, vertical: true)
            }
          }
          DeskCard {
            VStack(alignment: .leading, spacing: 8) {
              Text("子任务信息").font(.caption).foregroundStyle(.secondary)
              Text(snap.runs.isEmpty ? "暂无已报告的子任务" : "\(snap.runs.count) 项状态已返回").font(
                .system(size: 13, weight: .medium))
              Text(snap.childCoverage == "owner-reported" ? "来自原系统投影" : "覆盖仍待核实").font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        DeskCard { UsageTiles(snapshot: snap) }
        if model.page == "子任务" { RunsSection(session: session) }
        else if !snap.runs.isEmpty {
          DisclosureGroup("子任务 \(snap.runs.count) · 展开查看与操作") { RunsSection(session: session) }.font(.caption)
        }
        if model.page == "计划" { SchedulesSection(session: session) }
        if !model.actionNote.isEmpty {
          Label(model.actionNote, systemImage: "info.circle").font(.caption).foregroundStyle(
            .secondary
          ).fixedSize(horizontal: false, vertical: true)
        }
        OperationsSection(identity: snap.identity)
        SessionDiagnostics(session: session)
        Text("最后观测：" + Date(timeIntervalSince1970: snap.observedAt / 1000).formatted()).font(
          .caption2
        ).foregroundStyle(.tertiary)
      }
    } else {
      ContentUnavailableView(
        "选择一个会话", systemImage: "rectangle.stack", description: Text("查看状态、定位现场，或向原 Pi 追加要求。"))
    }
  }
}
struct RunsSection: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  @State private var texts: [String: String] = [:]
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 14) {
        Text("子任务").font(.subheadline.weight(.semibold))
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
        Text("已有计划").font(.subheadline.weight(.semibold))
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
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Toggle("静音本次提醒（不回答原问题）", isOn: $model.muted).font(.caption)
        ForEach(model.sessions, id: \.snapshot.identity) { s in
          if !s.snapshot.inputs.isEmpty || s.snapshot.execution == .failed {
            DeskCard {
              VStack(alignment: .leading, spacing: 11) {
                HStack {
                  Text(s.snapshot.display.name).font(.headline)
                  Spacer()
                  StatusPill(status: Presentation.status(s))
                }
                Text(Presentation.activity(s)).font(.subheadline)
                HStack {
                  Button("打开原会话") { model.openOriginal(identity: s.snapshot.identity) }
                  ForEach(s.snapshot.inputs) { i in
                    Button(model.isRead(i, session: s.snapshot.identity) ? "已读" : "标为已读") {
                      model.markRead(i, session: s.snapshot.identity)
                    }
                  }
                }.buttonStyle(.bordered)
              }
            }
          }
        }
        if model.inputCount == 0 {
          Label("当前没有已报告的待输入事项", systemImage: "checkmark.circle").font(.subheadline)
            .foregroundStyle(.secondary).padding(.vertical, 12)
        }
        Text("提醒关闭或发送失败不影响原问题、原通知与自动推进。").font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("治理与验证来源") {
          ForEach(model.sessions, id: \.snapshot.identity) { s in
            VStack(alignment: .leading, spacing: 6) {
              Text(s.snapshot.display.name).font(.caption.weight(.medium))
              if s.snapshot.evidence.isEmpty {
                Text("治理/CI 来源未配置").font(.caption).foregroundStyle(.secondary)
              }
              ForEach(s.snapshot.evidence) { e in
                Text(
                  e.category + " · 原系统报告 " + Presentation.runState(e.status) + " · "
                    + (e.nature == "advice" ? "建议" : "当前版本绑定未核验")
                ).font(.caption)
                Text(e.source + " · " + (e.head ?? "版本未知")).font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
              }
            }
          }
        }.font(.caption)
      }
    }
  }
}
struct SettingsPage: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
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
          Button("展开顶部速览") { model.showIsland() }.buttonStyle(.bordered)
        }
      }
      DeskCard {
        VStack(alignment: .leading, spacing: 12) {
          Text("原系统入口").font(.subheadline.weight(.semibold))
          TextField("Herdr 可执行文件绝对路径（可选）", text: $model.settings.herdrExecutable).textFieldStyle(
            .roundedBorder)
          TextField("精确 HTTPS 管理页（可选）", text: $model.settings.managementURL).textFieldStyle(
            .roundedBorder)
          Button("打开已配置管理页") { model.openManagement() }.disabled(
            LinkPolicy.exactHTTPS(model.settings.managementURL) == nil)
          Text("没有准确会话路由时会说明原因，不激活其他同名窗口。").font(.caption).foregroundStyle(.secondary)
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
          }.font(.caption)
          Text("仅主动点击开启时向系统申请许可；是否允许由你在系统提示中决定。拒绝或发送失败不影响原Pi通知与自动化。").font(.caption).foregroundStyle(.secondary)
          Button("保存本 App 设置") { model.saveSettings() }.buttonStyle(.bordered)
        }
      }
      if !model.actionNote.isEmpty {
        Text(model.actionNote).font(.caption).foregroundStyle(.secondary)
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
  }
}
