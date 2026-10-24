import AppKit
import PiDeskCore
import SwiftUI

@main struct PiDeskApplication: App {
  @StateObject private var model = AppModel()
  @Environment(\.openWindow) private var openWindow
  var body: some Scene {
    Window("Pi Desk", id: "manager") {
      DeskWindow().environmentObject(model).frame(minWidth: 960, minHeight: 620)
    }
    .defaultSize(width: 1160, height: 760)
    .commands {
      CommandGroup(after: .windowArrangement) {
        Button("打开管理窗口") { openWindow(id: "manager") }.keyboardShortcut("0", modifiers: [.command])
      }
    }
    MenuBarExtra {
      VStack(alignment: .leading, spacing: 12) {
        Text("Pi Desk · 自动化独立运行").font(.headline)
        Text("运行 \(model.activeCount) · 待输入 \(model.inputCount)")
        if model.sessions.isEmpty { Text("尚无已接入 Pi 会话").foregroundStyle(.secondary) }
        ForEach(model.sessions, id: \.snapshot.identity.sessionKey) { s in
          Button(
            s.snapshot.display.name + " · " + s.snapshot.execution.rawValue + " / "
              + s.connection.rawValue
          ) {
            model.selected = s.snapshot.identity.sessionKey
            openWindow(id: "manager")
          }
        }
        Divider()
        Button("打开管理窗口") {
          openWindow(id: "manager")
          NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("本次静音提醒", isOn: $model.muted)
        Button("退出 Pi Desk（Pi 继续）") {
          model.stop()
          NSApplication.shared.terminate(nil)
        }.keyboardShortcut("q")
      }.padding().frame(width: 330)
    } label: {
      Label("Pi \(model.activeCount) · \(model.inputCount)", systemImage: "circle.hexagongrid")
    }.menuBarExtraStyle(.window)
    Settings { SettingsPage().environmentObject(model).frame(width: 570).padding(24) }
  }
}

struct DeskWindow: View {
  @EnvironmentObject var model: AppModel
  let pages = ["会话", "子任务", "计划", "Token", "重要事项", "设置"]
  var body: some View {
    NavigationSplitView {
      List(pages, id: \.self, selection: $model.page) { p in Label(p, systemImage: icon(p)).tag(p) }
        .navigationTitle("Pi Desk").navigationSplitViewColumnWidth(150)
    } detail: {
      VStack(spacing: 0) {
        HStack {
          Label("Pi 按原规则独立推进", systemImage: "checkmark.shield")
          Spacer()
          Text(model.diagnostic).foregroundStyle(.secondary)
        }.font(.callout).padding(16)
        Divider()
        if model.page == "设置" {
          SettingsPage().padding(24)
          Spacer()
        } else if model.page == "Token" {
          TokenPage().padding(20)
          Spacer()
        } else if model.page == "重要事项" {
          AttentionPage().padding(20)
          Spacer()
        } else {
          HSplitView {
            SessionList().frame(minWidth: 240, idealWidth: 290, maxWidth: 360)
            ScrollView { SessionDetail().padding(22) }.frame(minWidth: 460)
          }
        }
      }
    }
    .toolbar {
      Button("刷新当前状态", systemImage: "arrow.clockwise") { model.refresh() }.disabled(
        model.current?.connection != .connected)
    }
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
    VStack(alignment: .leading) {
      Text("已主动接入的会话").font(.headline).padding()
      if model.sessions.isEmpty {
        ContentUnavailableView(
          "尚无已接入 Pi 会话", systemImage: "rectangle.stack", description: Text("显式加载桥接后显示。不扫描历史或进程。"))
      }
      List(selection: $model.selected) {
        ForEach(model.sessions, id: \.snapshot.identity.sessionKey) { s in
          VStack(alignment: .leading, spacing: 6) {
            Text(s.snapshot.display.name).font(.headline)
            Text(s.snapshot.display.model ?? "模型未知").font(.caption).foregroundStyle(.secondary)
            HStack {
              Text(s.snapshot.execution.rawValue)
              Spacer()
              Text(s.connection.rawValue)
            }.font(.caption)
            if !s.snapshot.inputs.isEmpty {
              Label("实际待输入 \(s.snapshot.inputs.count)", systemImage: "questionmark.circle").font(
                .caption)
            }
          }.padding(.vertical, 8).tag(s.snapshot.identity.sessionKey)
        }
      }
    }
  }
}
struct SessionDetail: View {
  @EnvironmentObject var model: AppModel
  @State private var message = ""
  @State private var mode = "followUp"
  var body: some View {
    if let s = model.current {
      let snap = s.snapshot
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          VStack(alignment: .leading) {
            Text(snap.display.name).font(.title2.bold())
            Text(snap.display.model ?? "模型未知").foregroundStyle(.secondary)
          }
          Spacer()
          Button("打开原会话") { model.openOriginal() }.disabled(s.connection != .connected)
        }
        HStack {
          badge("执行", snap.execution.rawValue)
          badge("连接", s.connection.rawValue)
          badge("思考档", snap.display.effort ?? "未知")
        }
        Text("当前 cwd 分支：" + (snap.display.branch ?? "未知/非 Git 目录"))
        if let omitted = snap.omitted, omitted.values.contains(where: { $0 > 0 }) {
          Text(
            "显示预算省略："
              + omitted.filter { $0.value > 0 }.map { "\($0.key) \($0.value)" }.sorted().joined(
                separator: ", ")
          ).font(.caption).foregroundStyle(.secondary)
        }
        Text("回合状态不代表目标、测试、合并或部署已验收。子任务覆盖：" + snap.childCoverage).font(.caption).foregroundStyle(
          .secondary)
        if let cwd = snap.display.cwd {
          DisclosureGroup("本机项目路径") {
            Text(cwd).font(.caption.monospaced()).textSelection(.enabled)
          }
        }
        if !snap.tools.isEmpty {
          Label(snap.tools.joined(separator: ", "), systemImage: "wrench.and.screwdriver")
        }
        if !snap.inputs.isEmpty {
          GroupBox("原会话正在等待输入") {
            ForEach(snap.inputs) { i in
              HStack {
                Text(i.kind + " · " + i.source)
                Spacer()
                Button("已读（不回答）") { model.markRead(i, session: snap.identity) }
              }
            }
          }
        }
        if model.page == "会话" {
          GroupBox("向此 Pi 发送要求") {
            VStack(alignment: .leading, spacing: 10) {
              Picker("递送方式", selection: $mode) {
                Text("追加 follow-up").tag("followUp")
                Text("纠偏 steer").tag("steer")
              }.pickerStyle(.segmented)
              TextEditor(text: $message).frame(height: 100).font(.body).accessibilityLabel(
                "管理消息，仅递送到选定会话")
              HStack {
                Button("发送要求") {
                  if model.action(
                    .message, target: Target(owner: "pi"),
                    parameters: Parameters(text: message, mode: mode))
                  {
                    message = ""
                  }
                }.disabled(
                  message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || message.utf8.count > 16384 || s.connection != .connected)
                Spacer()
                Button("中止当前回合", role: .destructive) {
                  model.action(.abortCurrent, target: Target(owner: "pi"))
                }.disabled(
                  s.connection != .connected || !snap.capabilities.actions.contains(.abortCurrent))
              }
              Text("发送返回 void 时只显示已请求；中止不清队列、不停独立孩子或计划。").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if model.page == "子任务" || model.page == "会话" {
          RunsSection(runs: snap.runs, connected: s.connection == .connected)
        }
        if model.page == "计划" {
          SchedulesSection(schedules: snap.schedules, connected: s.connection == .connected)
        }
        if !model.actionNote.isEmpty {
          Text(model.actionNote).font(.callout).textSelection(.enabled)
        }
        OperationsSection(identity: snap.identity)
        Text(
          "更新时间：" + Date(timeIntervalSince1970: snap.observedAt / 1000).formatted()
            + " · 来源合并 \(snap.dropped) · 接收跳帧 \(s.coalesced)"
        ).font(.caption).foregroundStyle(.secondary)
      }
    } else {
      ContentUnavailableView(
        "选择已接入会话", systemImage: "cursorarrow.click", description: Text("关闭窗口不会停止 Pi。"))
    }
  }
  func badge(_ title: String, _ value: String) -> some View {
    Text(title + "：" + value).font(.caption).padding(8).background(
      .quaternary, in: RoundedRectangle(cornerRadius: 6))
  }
}
struct RunsSection: View {
  @EnvironmentObject var model: AppModel
  let runs: [Run]
  let connected: Bool
  @State private var texts: [String: String] = [:]
  var body: some View {
    GroupBox("原 owner 子任务") {
      VStack(alignment: .leading, spacing: 12) {
        if runs.isEmpty { Text("没有可用 owner 运行投影；不推断所有子任务已结束").foregroundStyle(.secondary) }
        ForEach(runs) { r in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(r.agent ?? "子任务").bold()
              Spacer()
              Text(r.state)
            }
            Text(r.runId.map { "runId: " + $0 } ?? "Fleet 展示对象，不可用展示 key 控制").font(
              .caption.monospaced())
            if let runId = r.runId {
              let target = Target(owner: r.owner, runId: runId)
              if r.actions.contains(.steer) || r.actions.contains(.resume) {
                TextField(
                  "向此运行递送的要求",
                  text: Binding(get: { texts[r.key] ?? "" }, set: { texts[r.key] = $0 }))
              }
              HStack {
                if r.actions.contains(.steer) {
                  Button("纠偏") {
                    model.action(
                      .steer, target: target,
                      parameters: Parameters(text: texts[r.key], mode: "steer"))
                  }.disabled((texts[r.key] ?? "").isEmpty)
                }
                if r.actions.contains(.resume) {
                  Button("恢复原运行") {
                    model.action(
                      .resume, target: target, parameters: Parameters(text: texts[r.key]))
                  }.disabled((texts[r.key] ?? "").isEmpty)
                }
                if r.actions.contains(.stop) {
                  Button("请求停止", role: .destructive) { model.action(.stop, target: target) }
                }
              }.disabled(!connected)
            }
            Text("停止请求不等于进程终态。恢复资格由 owner 判断。").font(.caption).foregroundStyle(.secondary)
          }.padding(8).background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
struct SchedulesSection: View {
  @EnvironmentObject var model: AppModel
  let schedules: [Schedule]
  let connected: Bool
  var body: some View {
    GroupBox("已有计划（按 owner 分开）") {
      VStack(alignment: .leading, spacing: 12) {
        if schedules.isEmpty {
          Text("没有可用计划；未接 seam 的 owner 只能回原入口，不直接读写任务文件").foregroundStyle(.secondary)
        }
        ForEach(schedules) { s in
          VStack(alignment: .leading) {
            Text(s.name).bold()
            Text(s.owner + " · " + s.state).font(.caption)
            HStack {
              ForEach(s.actions, id: \.rawValue) { a in
                Button(title(a)) {
                  model.action(a, target: Target(owner: s.owner, scheduleId: s.scheduleId))
                }.disabled(!connected)
              }
            }
            Text("暂停只影响未来触发，不撤销已运行工作。").font(.caption).foregroundStyle(.secondary)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  func title(_ a: Action) -> String {
    switch a {
    case .pauseSchedule: return "暂停未来触发"
    case .resumeSchedule: return "恢复计划"
    case .runSchedule: return "请求触发"
    case .deleteSchedule: return "删除计划"
    default: return a.rawValue
    }
  }
}
struct OperationsSection: View {
  @EnvironmentObject var model: AppModel
  let identity: Identity
  var body: some View {
    let rows = model.store.requests.values.filter { $0.identity == identity }.sorted {
      $0.submittedAt > $1.submittedAt
    }.prefix(8)
    if !rows.isEmpty {
      GroupBox("本次界面请求（非任务库）") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(rows)) { r in
            VStack(alignment: .leading) {
              Text(r.action.rawValue + " · " + r.status)
              Text(r.code + (r.ownerRef.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(
                .secondary)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
struct TokenPage: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Token · 当前接入范围").font(.title2.bold())
        Spacer()
        Button("刷新选定 owner 统计") { model.refresh(usage: true) }.disabled(
          model.current?.connection != .connected)
      }
      Text("不同窗口、父子或会话之间没有可证明的不重叠归属时，不显示精确全局合计。上下文占用不是消耗；费用未知不代表免费。").foregroundStyle(.secondary)
      ScrollView {
        ForEach(model.sessions, id: \.snapshot.identity.sessionKey) { s in
          GroupBox(s.snapshot.display.name) {
            VStack(alignment: .leading, spacing: 12) {
              if let omitted = s.snapshot.omitted?["usage"], omitted > 0 {
                Text("显示预算省略统计报告 \(omitted)，覆盖不完整").font(.caption)
              }
              ForEach(Array(s.snapshot.usage.enumerated()), id: \.offset) { _, u in
                VStack(alignment: .leading, spacing: 6) {
                  Text(u.source + " · " + u.scope).bold()
                  Text("覆盖：" + u.coverage + " · 窗口 " + u.windowId).font(.caption)
                  Text(usageOrigin(u)).font(.caption)
                  Text(
                    "数据观测："
                      + (u.observedAt.map { Date(timeIntervalSince1970: $0 / 1000).formatted() }
                        ?? "尚无结算/owner未提供")
                  ).font(.caption)
                  HStack {
                    token("输入", u.tokens.input)
                    token("输出", u.tokens.output)
                    token("Cache read", u.tokens.cacheRead)
                    token("Cache write", u.tokens.cacheWrite)
                  }
                  Text(
                    "未覆盖孩子 " + (u.unresolvedChildren.map { String($0) } ?? "未知") + " · "
                      + u.reasons.joined(separator: ", ")
                  ).font(
                    .caption
                  ).foregroundStyle(.secondary)
                }
              }
              Text("上下文占用：" + number(s.snapshot.contextTokens)).font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }
  func usageOrigin(_ u: UsageReport) -> String {
    let start =
      u.startedAt.map { Date(timeIntervalSince1970: $0 / 1000).formatted() } ?? "owner 未提供"
    let model = u.model ?? "owner 累计，多模型或未知"
    return "来源模型：\(model) · 起点：\(start)"
  }
  func number(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "未知/尚未结算" }
  func token(_ label: String, _ v: Double?) -> some View {
    VStack(alignment: .leading) {
      Text(label).font(.caption)
      Text(number(v)).font(.system(.body, design: .monospaced))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct AttentionPage: View {
  @EnvironmentObject var model: AppModel
  func evidenceSource(_ e: Evidence) -> String {
    let head = e.head ?? "未知"
    let time = Date(timeIntervalSince1970: e.observedAt / 1000).formatted()
    return "来源 \(e.source) · head \(head) · \(time) · 不代表当前 merge/post-CI 已验真"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("重要事项").font(.title2.bold())
      Toggle("静音本次界面提醒（不回答原问题）", isOn: $model.muted)
      ScrollView {
        ForEach(model.sessions, id: \.snapshot.identity.sessionKey) { s in
          VStack(alignment: .leading, spacing: 10) {
            Text(s.snapshot.display.name).font(.headline)
            ForEach(s.snapshot.inputs) { i in
              HStack {
                Label(
                  i.kind + " · " + i.source,
                  systemImage: model.isRead(i, session: s.snapshot.identity)
                    ? "checkmark.circle" : "questionmark.circle")
                Spacer()
                Button("已读") { model.markRead(i, session: s.snapshot.identity) }
                Button("定位原会话") {
                  model.selected = s.snapshot.identity.sessionKey
                  model.openOriginal()
                }
              }
            }
            if s.snapshot.evidence.isEmpty { Text("治理/Gate/CI 来源未配置").foregroundStyle(.secondary) }
            ForEach(s.snapshot.evidence) { e in
              VStack(alignment: .leading) {
                Text(
                  e.category + " · owner 报告 " + e.status + " · "
                    + (e.nature == "advice" ? "建议" : "当前 head 未核验"))
                Text(evidenceSource(e)).font(.caption)
              }
            }
          }.padding(.vertical, 12)
        }
      }
      Text("没有原 producer 关联与可靠交付证明，不关闭原通知。Generic custom UI 不猜测问题来源。").font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
struct SettingsPage: View {
  @EnvironmentObject var model: AppModel
  var body: some View {
    Form {
      Section("本机连接") {
        Text(model.socketPath).font(.caption.monospaced())
        Text("主动加载扩展；不扫描历史、不自动安装或强 reload。").font(.caption)
      }
      Section("现有 owner 入口") {
        TextField("Herdr 绝对可执行路径（可选）", text: $model.settings.herdrExecutable)
        TextField("精确 HTTPS 管理页（可选）", text: $model.settings.managementURL)
        Button("打开已配置管理页") { model.openManagement() }.disabled(
          LinkPolicy.exactHTTPS(model.settings.managementURL) == nil)
      }
      Section("提醒") {
        Toggle("使用系统已授权的通知（不弹出新许可请求）", isOn: $model.settings.notifications)
        Text("未授权或发送失败时仅保留本窗口及原 producer 兜底。").font(.caption)
      }
      Button("保存本 App 设置") { model.saveSettings() }
      Text(model.actionNote).font(.caption)
      Section("不变边界") {
        Text("Pi Desk 不拥有 Pi 生命周期；退出、断联或更新不停止 Pi。不新增模型工具、审批、模型轮询或默认模型请求。").font(.callout)
      }
    }.formStyle(.grouped)
  }
}
