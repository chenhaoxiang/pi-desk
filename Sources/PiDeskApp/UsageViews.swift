import Charts
import PiDeskCore
import SwiftUI

struct AggregateTokenPage: View {
  @EnvironmentObject var model: AppModel
  private var usage: UsageAggregate { model.aggregate }
  private var metric: UsageMetric { model.usageMetric }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Pi 总用量").font(.system(size: 25, weight: .semibold))
            Text("所有已记录会话 · 不扫描旧会话，不是套餐额度或真实账单").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button { model.refreshUsage() } label: {
            Label(model.usageLoading ? "正在索引" : "刷新记录", systemImage: "arrow.clockwise")
          }.disabled(model.usageLoading || !model.customRangeIsValid).accessibilityLabel("刷新本机跨会话用量记录")
        }
        HStack {
          Picker("时间范围", selection: $model.usagePreset) {
            ForEach(UsagePreset.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented).frame(maxWidth: 370).labelsHidden()
          Spacer()
          VStack(alignment: .trailing, spacing: 3) {
            Text(rangeDates).font(.caption2)
            Text("本地时区：" + usage.timeZoneID + " · 原始记录：UTC").font(.caption2).foregroundStyle(.secondary)
          }.accessibilityElement(children: .combine)
        }
        HStack {
          Picker("模型", selection: $model.usageModel) {
            Text("所有已记录模型").tag("")
            ForEach(Array(Set(usage.availableModels + model.sessions.compactMap { $0.snapshot.display.model } + (model.usageModel.isEmpty ? [] : [model.usageModel]))).sorted(), id: \.self) { name in Text(name + (usage.availableModels.contains(name) ? "" : "（尚未采集）")).tag(name) }
          }.frame(maxWidth: 480)
          Spacer()
          Text("只按已记录final筛选，不把未采集填0").font(.caption2).foregroundStyle(.secondary)
        }
        let uncovered = model.sessions.filter { $0.connection == .connected && $0.snapshot.usageRecorder == nil }
        if !uncovered.isEmpty {
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
              Text("这些旧会话当前没有final持久采集器；新Pi正常启动时自动加载新版，不强制重载正在进行的工作，旧窗口累计不能补记日期。")
              Text("同一模型的新会话已记录数据仍单独计入总览；这里表示会话覆盖缺口，不表示整个模型都未采集。")
              ForEach(uncovered, id: \.snapshot.identity) { session in
                Text(session.snapshot.display.name + " · " + (session.snapshot.display.model ?? "模型未知")).font(.caption2)
              }
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
          } label: {
            Label("旧桥接未纳入：\(uncovered.count) 个在线会话 · 等待自然加载", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
          }
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
        HStack(spacing: 7) {
          Image(systemName: "internaldrive")
          Text(coverageStart).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Text("\(usage.recordCount) 条结算").monospacedDigit()
        }.font(.caption).foregroundStyle(.secondary).accessibilityElement(children: .combine)
        if let error = usage.error {
          Label("用量索引暂不可用 · 已保留旧数据（" + error + "）", systemImage: "externaldrive.badge.exclamationmark")
            .font(.caption).foregroundStyle(.orange)
        }
        DeskCard {
          VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 5) {
                Text("交互 Token · 输入 + 输出").font(.subheadline).foregroundStyle(.secondary)
                Text(value(usage.totals.metric(.interaction)))
                  .font(.system(size: 39, weight: .semibold, design: .rounded)).monospacedDigit()
                  .accessibilityLabel(exact(.interaction, usage.totals))
              }
              Spacer()
              Label("已记录下界", systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 20) {
              field("输入", usage.totals.input, known: usage.totals.inputKnown, complete: usage.totals.inputComplete, color: .blue)
              field("输出", usage.totals.output, known: usage.totals.outputKnown, complete: usage.totals.outputComplete, color: .green)
              Spacer()
            }
            Divider()
            HStack(alignment: .top, spacing: 25) {
              VStack(alignment: .leading, spacing: 6) {
                field("缓存读取", usage.totals.cacheRead, known: usage.totals.cacheReadKnown, complete: usage.totals.cacheReadComplete, color: .purple)
                Text("上下文复用量，不等于新输入或账单").font(.caption2).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
              VStack(alignment: .leading, spacing: 6) {
                field("缓存写入", usage.totals.cacheWrite, known: usage.totals.cacheWriteKnown, complete: usage.totals.cacheWriteComplete, color: .orange)
                Text("写入缓存的量，单独保留").font(.caption2).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
              VStack(alignment: .leading, spacing: 6) {
                Text("记录总处理量 · 四桶").font(.caption).foregroundStyle(.secondary)
                Text(value(usage.totals.metric(.processing))).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                  .accessibilityLabel(exact(.processing, usage.totals))
                Text("含缓存，不是新增Token或费用").font(.caption2).foregroundStyle(.secondary)
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        HStack {
          Picker("统计视图", selection: $model.usageMetric) {
            ForEach(UsageMetric.allCases) { Text($0.selector).tag($0) }
          }.pickerStyle(.segmented).frame(maxWidth: 300)
          Spacer()
          Text(metric.explanation).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.accessibilityLabel("趋势、日桶和模型分布采用同一统计视图")
        HStack {
          Text("所选视图：" + metric.title + " · " + value(usage.totals.metric(metric))).font(.subheadline.weight(.medium))
            .accessibilityLabel(exact(metric, usage.totals))
          Spacer()
          Text("图表与模型分布同口径").font(.caption2).foregroundStyle(.secondary)
        }
        DeskCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text((usage.range.hourly ? "按小时" : "按日") + metric.title).font(.headline)
              Spacer()
              Text("未采集留空，不代表零消费").font(.caption2).foregroundStyle(.secondary)
            }
            if usage.totals.metric(metric).known {
              UsageTrendChart(usage: usage, metric: metric).frame(height: 175)
            } else {
              ContentUnavailableView(usage.recordCount > 0 ? "此视图的用量字段未知" : "所选时间尚未采集", systemImage: "chart.bar.xaxis", description: Text(model.usageModel.isEmpty ? "仅从启用记录后累计；未采集不是零消费。" : "此时间尚未采集所选模型，不表示它消耗为0；旧桥接需等待自然加载。"))
                .frame(minHeight: 150)
            }
            if !usage.buckets.filter({ $0.state != .data }).isEmpty {
              Text(missingSummary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("图表数据 · " + metric.title) {
              LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(usage.buckets) { bucket in
                  HStack {
                    Text(dateLabel(bucket.day)); Spacer()
                    Text(bucket.state == .data ? value(bucket.tokens.metric(metric)) + " · 已记录下界" : (bucket.state == .future ? "尚未发生" : "尚未采集"))
                  }.font(.caption).accessibilityElement(children: .combine)
                }
              }.padding(.top, 8)
            }.font(.caption)
          }
        }
        DeskCard {
          VStack(alignment: .leading, spacing: 12) {
            HStack { Text("模型分布").font(.headline); Spacer(); Text(metric.title).font(.caption).foregroundStyle(.secondary) }
            if usage.models.isEmpty { Text("尚无已记录模型用量").font(.caption).foregroundStyle(.secondary) }
            ForEach(usage.models.sorted { $0.tokens.metric(metric).value > $1.tokens.metric(metric).value }) { entry in
              HStack {
                Text(entry.model).font(.subheadline).lineLimit(2).textSelection(.enabled)
                Spacer()
                Text(value(entry.tokens.metric(metric))).font(.subheadline.monospacedDigit())
              }.accessibilityElement(children: .combine).accessibilityLabel(entry.model + " · " + exact(metric, entry.tokens))
              GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3).fill(.blue.opacity(0.5))
                  .frame(width: max(0, geometry.size.width * Double(entry.tokens.metric(metric).value) / max(1, Double(usage.totals.metric(metric).value))))
              }.frame(height: 5).accessibilityHidden(true)
            }
          }
        }
        VStack(alignment: .leading, spacing: 7) {
          if let date = usage.refreshedAt { Text("索引更新 " + date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
          let old = model.sessions.filter { $0.connection == .connected && $0.snapshot.usageRecorder == nil }.count
          if old > 0 { Label("\(old) 个在线会话仍用旧桥接，未纳入持久时间统计；等待自然加载，不强制重载。", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
          if usage.conflicts > 0 || usage.malformed > 0 { Label("记录有冲突或不可读项，已保留原数据；当前为已知下界", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
          if usage.pendingRecords > 0 { Text("\(usage.pendingRecords) 条记录待索引或需检查").font(.caption).foregroundStyle(.orange) }
          DisclosureGroup("统计边界与记录状态") {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(usage.coverageReasons, id: \.self) { Text($0).font(.caption) }
              Text("原始时间使用UTC；以上按本地日历 " + usage.timeZoneID + " 分桶。" + utcRange).font(.caption)
              Text("四桶使用Pi归一语义。reasoning已含在输出，cacheWrite1h已含在缓存写入，不再相加。父owner累计、归属不明工具聚合不入时间账。")
              Text("记录总处理量含缓存复用，不代表新增输入、套餐余额或账单；未接入和采集启用前的消费未覆盖。")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
          }.font(.caption)
        }
        DisclosureGroup("当前会话用量（不同统计范围，不与总览相加）") { TokenPage() }.font(.caption)
      }.padding(24)
    }.onAppear { model.refreshUsage() }
      .onChange(of: model.usagePreset) { _, _ in model.refreshUsage() }
      .onChange(of: model.usageModel) { _, _ in model.refreshUsage() }
      .onChange(of: model.usageCustomStart) { _, _ in model.refreshUsage() }
      .onChange(of: model.usageCustomEnd) { _, _ in model.refreshUsage() }
  }
  private var coverageStart: String {
    guard let since = usage.collectedSince else { return "已有记录覆盖：尚未开始；启用前未采集，不以0补齐" }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = usage.range.timeZone
    let day = calendar.isDateInToday(since) ? "今日起" : calendar.isDateInYesterday(since) ? "昨日起" : dateText(since, format: "yyyy/M/d") + "起"
    return "已有记录覆盖：" + day + "（" + dateText(since, format: "M/d HH:mm") + "）；启用前未采集"
  }
  private var rangeDates: String { dateText(usage.range.start, format: "yyyy/M/d") + " — " + dateText(usage.range.endDate, format: "yyyy/M/d") }
  private var utcRange: String {
    let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd HH:mm"
    return "查询UTC边界：[" + f.string(from: usage.range.start) + ", " + f.string(from: usage.range.end) + ")"
  }
  private var missingSummary: String {
    let missing = usage.buckets.filter { $0.state == .uncollected }, future = usage.buckets.filter { $0.state == .future }
    return (missing.isEmpty ? "" : "尚未采集：" + missing.prefix(6).map { dateLabel($0.day) }.joined(separator: "、") + (missing.count > 6 ? "等\(missing.count)个桶" : "")) + (future.isEmpty ? "" : "　未来\(future.count)个桶尚未发生")
  }
  private func dateText(_ date: Date, format: String) -> String { let f = DateFormatter(); f.timeZone = usage.range.timeZone; f.dateFormat = format; return f.string(from: date) }
  private func dateLabel(_ date: Date) -> String { dateText(date, format: usage.range.hourly ? "HH:mm Z" : "M/d") }
  private func compact(_ value: Int64) -> String { Double(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
  private func value(_ value: UsageMetricValue) -> String { value.known ? (value.complete ? "" : "≥ ") + compact(value.value) : (usage.recordCount > 0 ? "未知" : "尚未采集") }
  private func exact(_ metric: UsageMetric, _ tokens: UsageTokenTotals) -> String { let v = tokens.metric(metric); return metric.title + " " + (v.known ? "\(v.value)，已记录下界" : "未知") }
  private func field(_ label: String, _ number: Int64, known: Bool, complete: Bool, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(label) }.font(.caption).foregroundStyle(.secondary)
      Text(!known ? "未知" : (complete ? "" : "≥ ") + compact(number)).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
        .accessibilityLabel(label + (known ? " \(number)" : "未知"))
    }.accessibilityElement(children: .combine)
  }
}
