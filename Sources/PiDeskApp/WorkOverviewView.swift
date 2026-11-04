import PiDeskCore
import SwiftUI

struct WorkOverviewPage: View {
  @EnvironmentObject var model: AppModel
  @State private var filter = "全部"
  var body: some View {
    let sessions = model.sessions
    let online = sessions.filter { $0.connection == .connected }
    let observed = online.filter { $0.snapshot.todo?.counts != nil }
    let needingInput = online.filter(Presentation.needsInput)
    let dependent = online.filter { !($0.snapshot.todo?.blocked.isEmpty ?? true) }
    let shown = sessions.filter { session in
      switch filter {
      case "需要你": return Presentation.needsInput(session)
      case "依赖阻塞": return session.connection == .connected && !(session.snapshot.todo?.blocked.isEmpty ?? true)
      case "任务未采集": return session.snapshot.todo?.counts == nil
      default: return true
      }
    }
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
          Text("看清工作，而不是只看会话在线").font(.title3.weight(.semibold))
          Text("Pi 是唯一事实来源；任务清单来自原生 Todo。完成记录不代表测试、交付或业务验收通过。").font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 20) {
            Label("\(needingInput.count) 个会话需要输入", systemImage: "person.crop.circle.badge.questionmark")
            Label("\(dependent.count) 个会话有依赖卡点", systemImage: "link")
            Label("\(observed.count)/\(online.count) 在线任务已观察", systemImage: "checklist")
          }.font(.caption).foregroundStyle(.secondary)
        }
        Picker("查看工作", selection: $filter) {
          ForEach(["全部", "需要你", "依赖阻塞", "任务未采集"], id: \.self) { Text($0).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        if sessions.isEmpty {
          ContentUnavailableView("尚无已接入 Pi", systemImage: "rectangle.stack", description: Text("等待正常接入。不启动新执行器、不扫描历史来填充看板。"))
        } else if shown.isEmpty {
          Text("当前没有符合此条件的会话。依赖等待不等于需要你审批。").font(.callout).foregroundStyle(.secondary).padding(20)
        }
        ForEach(shown, id: \.snapshot.identity) { session in WorkSessionCard(session: session) }
        Text("产品与跨会话工作项：原 owner 尚未提供明确绑定。本页不会把相同目录、名称或本机分组当成产品归属。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
      }.padding(22)
    }
  }
}
private struct WorkSessionCard: View {
  let session: SessionView
  @EnvironmentObject var model: AppModel
  var body: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text(model.nativeSessionTitle(session)).font(.headline).lineLimit(2)
            Text("工作归属未绑定 · " + Presentation.project(session.snapshot) + " · " + String(session.snapshot.identity.nativeSessionId.suffix(6))).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 10)
          StatusPill(status: Presentation.status(session))
        }
        HStack(alignment: .top) {
          Text("计划当前步骤").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
          Text(WorkOverview.currentTask(session)).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        if Presentation.needsInput(session) {
          Label("原会话正在等待输入；具体问题请回原入口查看。", systemImage: "questionmark.circle.fill").font(.caption).foregroundStyle(.orange)
        }
        TodoObservationCard(session: session, compact: true)
        Text(WorkOverview.guidance(session)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 12) {
          Button("查看任务与会话") { model.select(session.snapshot.identity); model.navigate(to: "会话") }
          Button(model.originalRouteLabel(identity: session.snapshot.identity)) { model.openOriginal(identity: session.snapshot.identity) }
            .disabled(!model.canOpenOriginal(identity: session.snapshot.identity))
          Spacer(minLength: 0)
          Text(SessionExperience.timing(session)).font(.caption2).foregroundStyle(.secondary)
        }.buttonStyle(.bordered).font(.caption)
      }
    }
  }
}
struct TodoObservationCard: View {
  let session: SessionView
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let todo = session.snapshot.todo {
        HStack {
          Label(todo.coverageTitle, systemImage: "checklist").font(.subheadline.weight(.medium))
          Spacer()
          if session.connection != .connected { Text("最后观测 · 已非实时").font(.caption).foregroundStyle(.orange) }
        }
        if let counts = todo.counts {
          Text("原计划：\(counts.completed) 项记录完成 · \(counts.inProgress) 项进行中 · \(counts.pending) 项未开始").font(.caption)
          if counts.total == 0 { Text("Pi 当前成功返回了空任务清单。").font(.caption).foregroundStyle(.secondary) }
          if compact {
            ForEach(Array(todo.tasks.filter { $0.status != "completed" }.prefix(3))) { task in TodoTaskRow(task: task) }
            if todo.tasks.count > 3 { Text("更多任务在会话详情中查看").font(.caption2).foregroundStyle(.secondary) }
          } else {
            ForEach(todo.tasks) { task in TodoTaskRow(task: task) }
          }
          if todo.omitted > 0 { Text("受显示预算限制，另有 \(todo.omitted) 项未展开；不是零任务或任务丢失。").font(.caption2).foregroundStyle(.orange) }
          if todo.coverage == "partial" { Text("任务信息存在省略、截断或安全隐藏，显示的关系可能不完整。").font(.caption2).foregroundStyle(.orange) }
          if let at = todo.observedAt { Text("来源：Pi Todo · " + Date(timeIntervalSince1970: at / 1000).formatted() + " · 观测序号 \(todo.observerSeq)").font(.caption2).foregroundStyle(.secondary) }
        } else {
          Text(todo.coverage == "unavailable" ? "当前原生任务快照不可投影；没有用旧清单替代当前事实。" : "尚未收到本运行当前范围的 Todo 结果，不代表没有任务。原会话下一次使用 Todo 后会更新；不触发模型或扫描历史补齐。").font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Label("任务观测未接入", systemImage: "info.circle").font(.subheadline.weight(.medium))
        Text("此桥接未提供原生Todo投影。正常新会话加载后可观察；不强制重载已有工作。").font(.caption).foregroundStyle(.secondary)
      }
      if !compact { Text("只读原计划；不能在这里勾选完成。负责人是Todo原字段，不是身份认证，任务完成也不替代验收。").font(.caption2).foregroundStyle(.secondary) }
    }
  }
}
private struct TodoTaskRow: View {
  let task: TodoRow
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .top) {
        Image(systemName: task.status == "completed" ? "checkmark.circle" : task.blocked ? "link" : task.status == "in_progress" ? "circle.lefthalf.filled" : "circle")
          .foregroundStyle(task.blocked ? Color.orange : Color.secondary)
        Text("#\(task.id) " + task.subject).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Text(task.statusTitle).font(.caption2).foregroundStyle(.secondary)
      }
      if task.status == "in_progress", let form = task.activeForm { Text(form).font(.caption).foregroundStyle(.secondary) }
      if let owner = task.owner { Text("原任务负责人标签：" + owner).font(.caption2).foregroundStyle(.secondary) }
      if task.blocked {
        Text("未满足依赖：" + task.unresolvedBy.map { "#\($0)" }.joined(separator: "、") + (task.omittedDependencies > 0 ? " · 另有依赖未完整显示" : ""))
          .font(.caption2).foregroundStyle(.orange)
      }
    }.padding(10).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }
}
