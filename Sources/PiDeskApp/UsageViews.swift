import Charts
import PiDeskCore
import SwiftUI

struct AggregateTokenPage: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.colorScheme) private var scheme
  private let labels = ["输入", "输出", "缓存读取", "缓存写入"]
  private let colors: [Color] = [.blue, .green, .purple, .orange]
  private var usage: UsageAggregate { model.aggregate }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Pi 总用量").font(.system(size: 25, weight: .semibold))
            Text("所有已记录会话 · 从启用采集起累计，不扫描旧会话").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button { model.refreshUsage() } label: {
            Label(model.usageLoading ? "正在索引" : "刷新记录", systemImage: "arrow.clockwise")
          }.disabled(model.usageLoading || !model.customRangeIsValid).accessibilityLabel("刷新本机跨会话用量记录")
        }
        HStack {
          Picker("时间范围", selection: $model.usagePreset) {
            ForEach(UsagePreset.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).frame(maxWidth: 400)
          Spacer()
          VStack(alignment: .trailing, spacing: 3) {
            Text(usage.range.start.formatted(date: .numeric, time: .omitted) + " — " + usage.range.endDate.formatted(date: .numeric, time: .omitted)).font(.caption2)
            Text(usage.timeZoneID).font(.caption).foregroundStyle(.secondary)
          }
            .accessibilityLabel("统计时区 " + usage.timeZoneID)
        }
        if model.usagePreset == .custom {
          HStack {
            DatePicker("开始日期", selection: $model.usageCustomStart, displayedComponents: .date)
            DatePicker("结束日期（含当天）", selection: $model.usageCustomEnd, displayedComponents: .date)
          }.datePickerStyle(.field).font(.caption)
          if !model.customRangeIsValid {
            Text("结束日期不能早于开始日期。未查询新范围，仍显示上次有效结果；请调整日期。")
              .font(.caption).foregroundStyle(.orange)
          }
        }
        if let error = usage.error {
          Label("用量索引暂不可用 · 已保留旧数据（" + error + "）", systemImage: "externaldrive.badge.exclamationmark")
            .font(.caption).foregroundStyle(.orange)
        }
        DeskCard {
          VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 5) {
                Text("已记录总 Token").font(.subheadline).foregroundStyle(.secondary)
                Text(usage.totals.anyKnown ? compact(usage.totals.totalLowerBound) : (usage.totals.seen ? "用量未知" : "尚未采集"))
                  .font(.system(size: 43, weight: .semibold, design: .rounded)).monospacedDigit()
                  .accessibilityLabel(usage.totals.anyKnown ? "已记录总Token \(usage.totals.totalLowerBound)，覆盖不完整" : "所选时间Token用量未知或尚未采集")
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 6) {
                Label("已知下界", systemImage: "info.circle").font(.caption.weight(.medium)).foregroundStyle(.orange)
                Text("不等于套餐余额或真实账单").font(.caption2).foregroundStyle(.secondary)
              }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 16) {
              tile("输入", value: usage.totals.input, known: usage.totals.inputKnown, complete: usage.totals.inputComplete, color: .blue)
              tile("输出", value: usage.totals.output, known: usage.totals.outputKnown, complete: usage.totals.outputComplete, color: .green)
              tile("缓存读取", value: usage.totals.cacheRead, known: usage.totals.cacheReadKnown, complete: usage.totals.cacheReadComplete, color: .purple)
              tile("缓存写入", value: usage.totals.cacheWrite, known: usage.totals.cacheWriteKnown, complete: usage.totals.cacheWriteComplete, color: .orange)
            }
          }
        }
        DeskCard {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Text(usage.range.hourly ? "按小时用量" : "按日用量").font(.headline)
              Spacer()
              Text("未采集留空，不代表零消费").font(.caption).foregroundStyle(.secondary)
            }
            if usage.totals.anyKnown {
              UsageTrendChart(usage: usage).frame(height: 220)
            } else {
              ContentUnavailableView(usage.recordCount > 0 ? "记录已到达，用量字段未知" : "所选时间尚未采集", systemImage: "chart.bar.xaxis", description: Text("新Pi自然加载新版桥接并结算后开始记录；不补扫旧JSONL，不用0冒充未知。"))
                .frame(minHeight: 170)
            }
            if !usage.buckets.filter({ $0.state != .data }).isEmpty {
              Text(missingSummary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("查看图表数据（键盘与辅助技术）") {
              LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(usage.buckets) { bucket in
                  HStack {
                    Text(dateLabel(bucket.day)); Spacer()
                    Text(bucket.state == .data ? (bucket.tokens.anyKnown ? compact(bucket.tokens.totalLowerBound) + " Token · 已记录" : "用量字段未知") : (bucket.state == .future ? "尚未发生" : "尚未采集"))
                  }.font(.caption).accessibilityElement(children: .combine)
                }
              }.padding(.top, 10)
            }.font(.caption)
          }
        }
        DeskCard {
          VStack(alignment: .leading, spacing: 14) {
            Text("模型分布").font(.headline)
            if usage.models.isEmpty { Text("尚无已记录模型用量").font(.caption).foregroundStyle(.secondary) }
            ForEach(usage.models) { entry in
              HStack {
                Text(entry.model).font(.subheadline).lineLimit(2).textSelection(.enabled)
                Spacer()
                Text(entry.tokens.anyKnown ? compact(entry.tokens.totalLowerBound) : "用量未知").font(.subheadline.monospacedDigit())
              }.accessibilityElement(children: .combine)
              GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3).fill(.blue.opacity(scheme == .dark ? 0.7 : 0.5))
                  .frame(width: max(0, geometry.size.width * Double(entry.tokens.totalLowerBound) / max(1, Double(usage.totals.totalLowerBound))))
              }.frame(height: 6).accessibilityHidden(true)
            }
          }
        }
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Label("本机记录 · \(usage.recordCount) 条结算", systemImage: "internaldrive")
            Spacer()
            if let date = usage.refreshedAt { Text("索引更新 " + date.formatted(date: .omitted, time: .standard)) }
          }.font(.caption).foregroundStyle(.secondary)
          if let since = usage.collectedSince {
            Text("最早已记录：" + since.formatted(date: .numeric, time: .shortened) + "；此前未采集，不追溯旧会话。")
              .font(.caption2).foregroundStyle(.secondary)
          }
          let old = model.sessions.filter { $0.connection == .connected && $0.snapshot.usageRecorder == nil }.count
          if old > 0 { Label("\(old) 个在线会话仍用旧桥接，未纳入持久时间统计；等待自然加载，不强制重载。", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
          if usage.conflicts > 0 || usage.malformed > 0 { Label("用量记录有冲突或不可读项，已保留原数据；总量为已知下界", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
          if usage.pendingRecords > 0 { Text("\(usage.pendingRecords) 条记录待索引或需检查").font(.caption).foregroundStyle(.orange) }
          DisclosureGroup("统计边界与记录状态") {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(usage.coverageReasons, id: \.self) { Text($0).font(.caption) }
              Text("四桶使用Pi归一语义。reasoning已含在输出、cacheWrite1h已含在缓存写入，不再次相加。owner生命周期累计与不可定位时间的工具聚合不计入此图。")
                .font(.caption)
              Text("缺字段保留已知下界；App关闭后bridge异步落盘，索引失败不停止Pi。未接入或未覆盖的消费不在总量内。")
                .font(.caption)
            }.foregroundStyle(.secondary).padding(.top, 8)
          }.font(.caption)
        }
        DisclosureGroup("当前会话用量（不同统计范围，不与总览相加）") { TokenPage() }.font(.caption)
      }.padding(24)
    }.onAppear { model.refreshUsage() }
      .onChange(of: model.usagePreset) { _, _ in model.refreshUsage() }
      .onChange(of: model.usageCustomStart) { _, _ in model.refreshUsage() }
      .onChange(of: model.usageCustomEnd) { _, _ in model.refreshUsage() }
  }
  private var missingSummary: String {
    let missing = usage.buckets.filter { $0.state == .uncollected }
    let future = usage.buckets.filter { $0.state == .future }
    return (missing.isEmpty ? "" : "尚未采集：" + missing.prefix(8).map { dateLabel($0.day) }.joined(separator: "、") + (missing.count > 8 ? "等\(missing.count)个桶" : "")) + (future.isEmpty ? "" : "　未来\(future.count)个桶尚未发生")
  }
  private func values(_ t: UsageTokenTotals) -> [Int64] { [t.input, t.output, t.cacheRead, t.cacheWrite] }
  private func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.timeZone = usage.range.timeZone
    formatter.dateFormat = usage.range.hourly ? "HH:mm Z" : "M/d"
    return formatter.string(from: date)
  }
  private func compact(_ value: Int64) -> String {
    Double(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
  }
  private func tile(_ label: String, value: Int64, known: Bool, complete: Bool, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(label) }.font(.caption).foregroundStyle(.secondary)
      Text(!usage.totals.seen || !known ? "未知" : (complete ? "" : "≥ ") + compact(value)).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
    }.accessibilityElement(children: .combine)
  }
}
