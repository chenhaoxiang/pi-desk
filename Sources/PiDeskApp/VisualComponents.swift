import AppKit
import PiDeskCore
import SwiftUI

extension StatusTone {
  func ink(dark: Bool) -> Color {
    if dark { return color }
    switch self {
    case .green: return Color(red: 0.10, green: 0.39, blue: 0.27)
    case .amber: return Color(red: 0.55, green: 0.30, blue: 0.03)
    case .blue: return Color(red: 0.10, green: 0.35, blue: 0.70)
    case .red: return Color(red: 0.68, green: 0.11, blue: 0.12)
    case .muted: return .secondary
    }
  }
  var color: Color {
    switch self {
    case .green: return Color(red: 0.30, green: 0.80, blue: 0.57)
    case .amber: return Color(red: 0.95, green: 0.65, blue: 0.28)
    case .blue: return Color(red: 0.34, green: 0.65, blue: 0.95)
    case .red: return .red
    case .muted: return .secondary
    }
  }
}
struct PiMark: View {
  var size: CGFloat = 22
  var body: some View {
    Text("π").font(.system(size: size, weight: .semibold, design: .rounded)).accessibilityLabel(
      "Pi")
  }
}
struct StatusPill: View {
  @Environment(\.colorScheme) private var scheme
  let status: HumanStatus
  var body: some View {
    Label(status.title, systemImage: status.symbol).font(.system(size: 11, weight: .semibold))
      .foregroundStyle(status.tone.ink(dark: scheme == .dark)).padding(.horizontal, 9).padding(
        .vertical, 5
      ).background(
        status.tone.color.opacity(0.12), in: Capsule()
      ).accessibilityElement(children: .combine)
  }
}
struct DeskCard<Content: View>: View {
  @ViewBuilder var content: () -> Content
  var body: some View {
    content().frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)
    ).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.06), lineWidth: 1))
  }
}
struct PreviewBadge: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    Label("合成预览", systemImage: "viewfinder").font(.caption2.weight(.semibold)).foregroundStyle(
      StatusTone.amber.ink(dark: scheme == .dark)
    ).padding(.horizontal, 8).padding(.vertical, 4).background(.orange.opacity(0.12), in: Capsule())
  }
}
struct SessionCard: View {
  let session: SessionView
  var selected = false
  var island = false
  var onSelect: () -> Void
  @EnvironmentObject var model: AppModel
  var append: ((Identity, String) -> Void)?
  var body: some View {
    HStack(spacing: 12) {
      RoundedRectangle(cornerRadius: 3).fill(Presentation.status(session).tone.color).frame(
        width: 3)
      VStack(alignment: .leading, spacing: 9) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(session.snapshot.display.name).font(
            .system(size: island ? 15 : 14, weight: .semibold)
          ).lineLimit(island ? 1 : 2).fixedSize(horizontal: false, vertical: true).help(session.snapshot.display.name)
          Spacer(minLength: 0)
          HStack(spacing: 6) {
            StatusPill(status: Presentation.connectionStatus(session))
            StatusPill(status: Presentation.status(session))
          }
        }
        Text(metadata + " · " + Presentation.createdShort(session.snapshot)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        HStack(spacing: 7) {
          Image(
            systemName: session.snapshot.tools.isEmpty ? "circle.dotted" : "wrench.and.screwdriver"
          ).foregroundStyle(Presentation.status(session).tone.color)
          Text(Presentation.activity(session)).lineLimit(island ? 1 : 2)
        }.font(.system(size: 12)).foregroundStyle(.primary.opacity(0.86))
        if !session.snapshot.runs.isEmpty {
          Label(
            session.connection != .connected
              ? "子任务状态待更新"
              : session.snapshot.runs.contains(where: { $0.state == "running" })
                ? "有已报告的子任务正在运行" : "子任务状态已更新", systemImage: "point.3.connected.trianglepath.dotted"
          ).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if island {
          HStack(spacing: 8) {
            Button("查看详情", action: onSelect).buttonStyle(.bordered)
            Button(model.originalRouteLabel(identity: session.snapshot.identity)) { model.openOriginal(identity: session.snapshot.identity) }.buttonStyle(.borderless)
              .disabled(!model.canOpenOriginal(identity: session.snapshot.identity))
            Spacer()
            if session.connection == .connected {
              Button {
                append?(session.snapshot.identity, "followUp")
              } label: {
                Image(systemName: "text.badge.plus")
              }.help("追加要求").accessibilityLabel("向" + session.snapshot.display.name + "追加要求")
            }
          }.font(.system(size: 11))
        }
        if !island && session.snapshot.childCoverage != "owner-reported" {
          Text("子任务信息待核 · " + Presentation.usage(session.snapshot).coverage).font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }
    }.padding(island ? 13 : 12).background(
      selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 14)
    ).overlay(
      RoundedRectangle(cornerRadius: 14).stroke(
        selected ? Color.accentColor.opacity(0.32) : .primary.opacity(island ? 0.08 : 0.05),
        lineWidth: 1)
    ).contentShape(RoundedRectangle(cornerRadius: 14))
      .accessibilityElement(children: .contain)
  }
  var metadata: String {
    let s = session.snapshot
    let project = [Presentation.project(s), s.display.branch, Presentation.shortModel(s)].compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: " · ")
    return [Presentation.connection(session.connection), Presentation.status(session).title, project]
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
struct MessageComposer: View {
  let identity: Identity
  let mode: String
  var close: () -> Void
  var editing: (Bool) -> Void = { _ in }
  @EnvironmentObject var model: AppModel
  @FocusState private var focused: Bool
  private var session: SessionView? {
    guard let s = model.store.sessions[identity.sessionKey], s.snapshot.identity == identity else {
      return nil
    }
    return s
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(
          mode == "steer" ? "纠偏" : "追加要求",
          systemImage: mode == "steer" ? "arrow.triangle.branch" : "text.badge.plus"
        ).font(.subheadline.weight(.semibold))
        Spacer()
        Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起输入，保留草稿")
      }
      TextField(
        "写下要递送给此会话的要求…",
        text: Binding(
          get: { model.drafts[identity] ?? "" }, set: { model.setDraft($0, for: identity) }),
        axis: .vertical
      ).lineLimit(2...4).textFieldStyle(.plain).padding(10).background(
        .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)
      ).focused($focused).accessibilityLabel("只递送给当前选定会话的要求")
      HStack {
        Text(session == nil ? "会话已更新，草稿保留；请重新选择准确对象" : "递送到原会话，回执不代表任务完成").font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("发送要求", action: send).buttonStyle(.borderedProminent).disabled(
          (model.drafts[identity] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (model.drafts[identity]?.utf8.count ?? 0) > 16384
            || session?.connection != .connected
        ).keyboardShortcut(.return, modifiers: .command)
      }
    }.padding(14).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08), lineWidth: 1))
      .onAppear {
        focused = true
        editing(true)
      }.onDisappear { editing(false) }.onChange(of: focused) { _, value in editing(value) }
      .onExitCommand {
        focused = false
        close()
      }
  }
  func send() {
    if model.action(
      .message, target: Target(owner: "pi"),
      parameters: Parameters(text: model.drafts[identity], mode: mode), identity: identity)
    {
      model.setDraft("", for: identity)
      close()
    }
  }
}
struct SessionActions: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  @State private var mode: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 9) {
        Button {
          model.openOriginal(identity: session.snapshot.identity)
        } label: {
          Label(model.originalRouteLabel(identity: session.snapshot.identity), systemImage: "arrow.up.right")
        }.buttonStyle(.borderedProminent).disabled(!model.canOpenOriginal(identity: session.snapshot.identity))
        Button("追加要求") { mode = "followUp" }.buttonStyle(.bordered).disabled(
          session.connection != .connected)
        Button("纠偏") { mode = "steer" }.buttonStyle(.bordered).disabled(
          session.connection != .connected)
        Menu {
          Button("中止当前回合", role: .destructive) {
            model.action(
              .abortCurrent, target: Target(owner: "pi"), identity: session.snapshot.identity)
          }.disabled(
            session.connection != .connected
              || !session.snapshot.capabilities.actions.contains(.abortCurrent))
          Text("只中止当前回合，不清队列或停止独立子任务")
        } label: {
          Image(systemName: "ellipsis")
        }.menuStyle(.borderlessButton).frame(width: 26).help("更多操作")
        Spacer()
      }
      if let mode = mode {
        MessageComposer(identity: session.snapshot.identity, mode: mode, close: { self.mode = nil })
          .id(session.snapshot.identity)
      }
    }
  }
}
struct UsageTiles: View {
  let snapshot: Snapshot
  var body: some View {
    let usage = Presentation.usage(snapshot)
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Label("用量概览", systemImage: "chart.bar.xaxis").font(.subheadline.weight(.medium))
        Spacer()
        Text(usage.scope + " · " + usage.coverage).font(.caption).foregroundStyle(.secondary)
      }
      HStack(spacing: 22) {
        tile("输入", usage.tokens.input)
        tile("输出", usage.tokens.output)
        tile("缓存读取", usage.tokens.cacheRead)
        tile("缓存写入", usage.tokens.cacheWrite)
      }
      Text("统计不完整时保留未知，不将不同范围或父子报告重复相加。").font(.caption).foregroundStyle(.secondary)
    }
  }
  func tile(_ title: String, _ value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(Presentation.count(value)).font(.system(size: 21, weight: .medium, design: .rounded))
        .monospacedDigit()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct SessionDiagnostics: View {
  let session: SessionView
  var body: some View {
    DisclosureGroup("诊断信息") {
      VStack(alignment: .leading, spacing: 9) {
        line("桥接源码", session.snapshot.capabilities.owners["pi-desk-bridge"] ?? "未提供")
        if let recorder = session.snapshot.usageRecorder {
          line("用量采集器", "final持久记录已启用 · 待落盘 \(recorder.pending) · 丢弃 \(recorder.dropped) · 写盘失败 \(recorder.writeFailures)")
          line("采集说明", recorder.reasons.joined(separator: ", "))
        } else {
          line("用量采集器", "旧桥接未纳入持久时间统计；等待新Pi正常启动时自然加载，不强制重载当前工作")
        }
        line("会话ID", session.snapshot.identity.nativeSessionId)
        line("运行代际", session.snapshot.identity.runtimeEpoch)
        line("原始状态", session.snapshot.execution.rawValue + " / " + session.connection.rawValue)
        line("执行状态依据", Presentation.executionCoverage(session))
        if let proof = session.snapshot.executionObservation {
          line("执行观测时间", Date(timeIntervalSince1970: proof.observedAt / 1000).formatted() + " · " + proof.source + " · idle=\(proof.idle)")
        }
        line("子任务覆盖", session.snapshot.childCoverage)
        if let omitted = session.snapshot.omitted {
          line(
            "省略的显示项",
            omitted.filter { $0.value > 0 }.map { "\($0.key): \($0.value)" }.sorted().joined(
              separator: ", "))
        }
        line("完整模型", session.snapshot.display.model ?? "未提供")
        line(
          "思考档",
          Presentation.effort(session.snapshot.display.effort) + " · "
            + (session.snapshot.display.effort ?? "未提供"))
        line("项目路径", session.snapshot.display.cwd ?? "未提供")
        ForEach(session.snapshot.inputs) { input in
          line("输入来源", input.source + " · " + input.kind)
          line("输入事件", input.id)
        }
        Text("来源合并 \(session.snapshot.dropped) · 接收跳帧 \(session.coalesced)").font(.caption)
        ForEach(Array(session.snapshot.usage.enumerated()), id: \.offset) { _, u in
          line("统计来源", u.source + " · " + u.scope + " · " + u.coverage)
          line(
            "统计覆盖",
            Presentation.coverage(u.coverage) + " · 未覆盖子任务 "
              + (u.unresolvedChildren.map { String($0) } ?? "未知"))
          line("统计窗口", u.windowId)
          line(
            "观测时间",
            u.observedAt.map { Date(timeIntervalSince1970: $0 / 1000).formatted() } ?? "尚无结算/未提供")
          line(
            "窗口起点", u.startedAt.map { Date(timeIntervalSince1970: $0 / 1000).formatted() } ?? "未提供")
          line("统计说明", u.reasons.joined(separator: ", "))
        }
      }.padding(.top, 12).foregroundStyle(.secondary)
    }.font(.caption).tint(.secondary)
  }
  func line(_ key: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(key).fontWeight(.medium)
      Text(value).font(.caption.monospaced()).textSelection(.enabled).fixedSize(
        horizontal: false, vertical: true)
    }
  }
}
struct IslandView: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var island: IslandController
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  var body: some View {
    Group { if island.state.expanded { expanded } else { compact } }.foregroundStyle(.white)
      .background(
        Color(red: 0.025, green: 0.03, blue: 0.032),
        in: RoundedRectangle(cornerRadius: island.state.expanded ? 24 : 18)
      ).overlay(
        RoundedRectangle(cornerRadius: island.state.expanded ? 24 : 18).stroke(
          .white.opacity(0.10), lineWidth: 1)
      ).preferredColorScheme(.dark).animation(
        (reduceMotion || island.reducedMotion) ? nil : .easeInOut(duration: 0.16),
        value: island.state.expanded)
  }
  var compactSummary: String {
    if model.diagnostic.hasPrefix("连接不可用") { return "连接暂不可用" }
    if model.activeCount > 0 { return "\(model.activeCount) 已确认执行" }
    if model.unknownExecutionCount > 0 { return "\(model.unknownExecutionCount) 执行状态待核" }
    if model.sessions.isEmpty { return "等待接入" }
    if model.connectedCount == 0 { return "已接入0 · 连接待恢复" }
    return "已接入 \(model.connectedCount) · 暂时空闲"
  }
  var compact: some View {
    Button {
      island.revealForInteraction()
    } label: {
      HStack(spacing: island.geometry.cameraGap > 0 ? 0 : 12) {
        HStack(spacing: 12) {
          PiMark(size: 21)
          HStack(spacing: 5) {
            Circle().fill(model.activeCount > 0 ? StatusTone.green.color : .gray).frame(
              width: 5, height: 5)
            Text(compactSummary).font(.system(size: 11, weight: .medium))
          }
        }.frame(width: island.geometry.cameraGap > 0 ? 117 : nil, alignment: .leading)
        if island.geometry.cameraGap > 0 {
          Color.clear.frame(width: island.geometry.cameraGap)
        } else {
          Divider().frame(height: 13).overlay(.white.opacity(0.16))
        }
        Text(
          model.inputCount > 0
            ? "\(model.inputCount) 需输入" : model.isPreview ? "预览" : "已接入 \(model.connectedCount)"
        ).font(.system(size: 11, weight: .medium)).foregroundStyle(
          model.inputCount > 0 ? StatusTone.amber.color : .secondary
        ).frame(width: island.geometry.cameraGap > 0 ? 117 : nil, alignment: .trailing)
      }.padding(.horizontal, 17).frame(maxWidth: .infinity, maxHeight: .infinity)
    }.buttonStyle(.plain).accessibilityLabel("展开 Pi Desk 顶部速览").help("悬停或点击，展开会话速览")
  }
  var expanded: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        PiMark().foregroundStyle(.white)
        Text("Pi Desk").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        if model.isPreview { PreviewBadge() }
        Spacer()
        Button {
          island.pin()
        } label: {
          Image(systemName: island.state.pinned ? "pin.fill" : "pin")
        }.help(island.state.pinned ? "取消固定" : "固定展开").accessibilityLabel(
          island.state.pinned ? "取消固定灵动岛" : "固定灵动岛")
        Button {
          island.openManager()
        } label: {
          Image(systemName: "arrow.up.right.square")
        }.help("打开管理窗口").accessibilityLabel("打开管理窗口")
        Button {
          island.collapse()
        } label: {
          Image(systemName: "chevron.up")
        }.help("收起灵动岛").accessibilityLabel("收起灵动岛")
      }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 19).padding(
        .top, island.geometry.topInset + 14
      ).padding(.bottom, 13)
      HStack(spacing: 17) {
        Text("全部 \(model.sessions.count)")
        Text("运行中 \(model.activeCount)")
        Text("需输入 \(model.inputCount)").foregroundStyle(
          model.inputCount > 0 ? StatusTone.amber.color : .secondary)
        Spacer()
        Text("不打断自动化").foregroundStyle(.secondary)
      }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 20).padding(.bottom, 12)
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 18)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 9) {
            if model.sessions.isEmpty {
              VStack(spacing: 10) {
                Image(systemName: "rectangle.stack").font(.title2)
                Text("尚无已接入会话").font(.headline)
                Text("新 Pi 会话会按已安装入口自然接入，关闭这里不会停止 Pi。").font(.caption).foregroundStyle(.secondary)
                  .multilineTextAlignment(.center)
              }.frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            ForEach(Array(model.sessions.prefix(4)), id: \.snapshot.identity) { s in
              SessionCard(
                session: s, island: true, onSelect: { island.openManager(s.snapshot.identity) },
                append: { id, mode in island.compose(id, mode: mode) })
            }
            if let identity = island.composing {
              MessageComposer(
                identity: identity, mode: island.mode, close: { island.finishComposing() },
                editing: { island.editing($0) }
              ).id(identity).id("island-composer")
            }
            if model.sessions.count > 4 {
              Button("另有 \(model.sessions.count-4) 个会话，打开管理窗口查看") { island.openManager() }.font(
                .caption
              ).buttonStyle(.plain).foregroundStyle(.secondary)
            }
          }.padding(12)
        }.scrollIndicators(.hidden).onChange(of: island.composing) { _, value in
          if value != nil {
            DispatchQueue.main.async {
              if island.reducedMotion {
                proxy.scrollTo("island-composer", anchor: .bottom)
              } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                  proxy.scrollTo("island-composer", anchor: .bottom)
                }
              }
            }
          }
        }
      }
      HStack {
        Label("Pi 独立运行", systemImage: "checkmark.shield")
        Spacer()
        if !model.actionNote.isEmpty {
          Text(model.actionNote).lineLimit(1)
        } else {
          Text("Esc 收起 · 编辑时保留展开")
        }
      }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 19).padding(
        .vertical, 12)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
