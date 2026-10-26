import Charts
import PiDeskCore
import SwiftUI

struct AggregateTokenPage: View {
  @EnvironmentObject var model: AppModel
  @State private var showDetails = false
  private var usage: UsageAggregate { model.aggregate }
  private var metric: UsageMetric { model.usageMetric }
  private var oldSessions: [SessionView] { model.usageOrigin == .history ? [] : model.sessions.filter { $0.connection == .connected && $0.snapshot.usageRecorder == nil } }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        filterBar
        if model.usagePreset == .custom {
          HStack(spacing: 16) {
            DatePicker("开始", selection: $model.usageCustomStart, displayedComponents: .date)
            DatePicker("结束（含当天）", selection: $model.usageCustomEnd, displayedComponents: .date)
            Spacer(minLength: 0)
          }.datePickerStyle(.field)
          if !model.customRangeIsValid {
            Label("结束日期不能早于开始日期；仍显示上次有效结果。", systemImage: "exclamationmark.triangle")
              .font(.caption).foregroundStyle(.orange)
          }
        }
        HStack(spacing: 8) {
          Text(rangeDates + " · " + usage.timeZoneID).lineLimit(1).help("原始时间UTC；本地日历半开区间。" + utcRange)
          Spacer(minLength: 4)
          Text(model.usageLoading ? "更新中…" : updateLabel).monospacedDigit()
        }.font(.caption).foregroundStyle(.secondary)
        if let warning = shortWarning {
          Label(warning, systemImage: usage.error == nil ? "info.circle" : "externaldrive.badge.exclamationmark")
            .font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
        summaryCard
        trendCard
        DisclosureGroup(isExpanded: $showDetails) {
          recordDetails.padding(.top, 8)
        } label: {
          HStack {
            Text("来源、覆盖与导入收据")
            Spacer()
            Text("\(usage.recordCount.formatted()) 条唯一消费").foregroundStyle(.secondary)
          }
        }.font(.caption)
        modelCard
        DisclosureGroup("图表数据 · " + metric.title) {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(usage.buckets) { bucket in
              HStack {
                Text(dateLabel(bucket.day)); Spacer()
                Text(bucket.state == .data ? value(bucket.tokens.metric(metric)) + " · 已记录下界" : (bucket.state == .future ? "尚未发生" : "尚未采集"))
              }.accessibilityElement(children: .combine)
            }
          }.padding(.top, 8)
        }.font(.caption)
        DisclosureGroup("当前会话用量（不同范围，不与总览相加）") { TokenPage() }.font(.caption)
      }.padding(18)
    }.onAppear { model.refreshUsage() }
      .onChange(of: model.usagePreset) { _, _ in model.persistViewState(); model.refreshUsage() }
      .onChange(of: model.usageModel) { _, _ in model.persistViewState(); model.refreshUsage() }
      .onChange(of: model.usageOrigin) { _, _ in model.persistViewState(); model.refreshUsage() }
      .onChange(of: model.usageMetric) { _, _ in model.persistViewState() }
      .onChange(of: model.usageCustomStart) { _, _ in model.persistViewState(); model.refreshUsage() }
      .onChange(of: model.usageCustomEnd) { _, _ in model.persistViewState(); model.refreshUsage() }
  }
  private var filterBar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        timePicker.frame(width: 250)
        originPicker.frame(width: 145)
        modelPicker.frame(minWidth: 150, maxWidth: .infinity)
        refreshButton
      }
      VStack(spacing: 8) {
        HStack(spacing: 10) { timePicker; refreshButton }
        HStack(spacing: 10) { originPicker.frame(width: 145); modelPicker }
      }
    }
  }
  private var timePicker: some View {
    Picker("时间范围", selection: $model.usagePreset) {
      ForEach(UsagePreset.allCases) { Text($0.rawValue).tag($0) }
    }.pickerStyle(.segmented).labelsHidden()
  }
  private var originPicker: some View {
    Picker("记录来源", selection: $model.usageOrigin) {
      ForEach(UsageOrigin.allCases) { Text($0.title).tag($0) }
    }.pickerStyle(.menu).labelsHidden().accessibilityLabel("记录来源")
  }
  private var modelPicker: some View {
    Picker("模型", selection: $model.usageModel) {
      Text("所有已记录模型").tag("")
      ForEach(Array(Set(usage.availableModels + model.sessions.compactMap { $0.snapshot.display.model } + (model.usageModel.isEmpty ? [] : [model.usageModel]))).sorted(), id: \.self) { name in
        Text(name + (usage.availableModels.contains(name) ? "" : "（尚未采集）")).tag(name)
      }
    }.pickerStyle(.menu).labelsHidden().lineLimit(1).truncationMode(.middle)
      .accessibilityLabel("筛选用量模型").help(model.usageModel.isEmpty ? "所有已记录模型" : model.usageModel)
  }
  private var refreshButton: some View {
    Button { model.refreshUsage() } label: { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
      .disabled(model.usageLoading || !model.customRangeIsValid).help("刷新本机用量记录")
      .accessibilityLabel("刷新本机跨会话用量记录")
  }
  private var summaryCard: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text(metric.title).font(.subheadline).foregroundStyle(.secondary)
            Text(value(usage.totals.metric(metric)))
              .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
              .accessibilityLabel(exact(metric, usage.totals))
          }
          Spacer(minLength: 10)
          VStack(alignment: .trailing, spacing: 7) {
            Picker("统计口径", selection: $model.usageMetric) {
              ForEach(UsageMetric.allCases) { Text($0.selector).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            Text("已记录下界 · 非账单").font(.caption).foregroundStyle(.secondary)
          }
        }
        Text(metric.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Divider()
        Grid(horizontalSpacing: 18, verticalSpacing: 0) {
          GridRow {
            tokenField("输入", usage.totals.input, known: usage.totals.inputKnown, complete: usage.totals.inputComplete, color: .blue)
            tokenField("输出", usage.totals.output, known: usage.totals.outputKnown, complete: usage.totals.outputComplete, color: .green)
            tokenField("缓存读取", usage.totals.cacheRead, known: usage.totals.cacheReadKnown, complete: usage.totals.cacheReadComplete, color: .purple)
            tokenField("缓存写入", usage.totals.cacheWrite, known: usage.totals.cacheWriteKnown, complete: usage.totals.cacheWriteComplete, color: .orange)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  private var trendCard: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(usage.range.hourly ? "按小时趋势" : "按日趋势").font(.subheadline.weight(.semibold))
          Spacer()
          Text("空白不代表零消费").font(.caption).foregroundStyle(.secondary)
        }
        if usage.totals.metric(metric).known {
          UsageTrendChart(usage: usage, metric: metric).equatable().frame(height: 175)
        } else {
          ContentUnavailableView(usage.recordCount > 0 ? "所选字段未知" : "所选时间尚未采集", systemImage: "chart.bar.xaxis", description: Text("只展示已有记录，不以0补齐未知消费。"))
            .frame(height: 175)
        }
      }
    }
  }
  private var modelCard: some View {
    DeskCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack { Text("模型分布").font(.subheadline.weight(.semibold)); Spacer(); Text(metric.title).font(.caption).foregroundStyle(.secondary) }
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
  }
  private var recordDetails: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(coverageStart)
      Text(missingSummary)
      ForEach([UsageOrigin.realtime, .history]) { source in
        HStack {
          Text(source.title)
          Spacer()
          Text("\(usage.originCounts[source.rawValue] ?? 0) 条 · " + value((usage.originTotals[source.rawValue] ?? UsageTokenTotals()).metric(metric))).monospacedDigit()
        }
      }
      Text("以上两来源按同一消费键去重；实时重叠沿用原来源，fork继承只计原消费。不再另列与主卡重复的合计数值。")
      if let imported = usage.historyImportedAt {
        Text("一次性历史补采收据 · " + imported.formatted(date: .numeric, time: .shortened)).fontWeight(.medium)
        if let from = usage.historyMinDate, let to = usage.historyMaxDate { Text("文件已知usage覆盖：" + dateText(from, format: "yyyy/M/d") + " — " + dateText(to, format: "yyyy/M/d")) }
        ForEach(usage.historyReasons, id: \.self) { Text($0) }
        Text("仅恢复元数据；未知物理模型不猜成GPT，缺字段不补0。导入只执行一次，不在启动或刷新时再扫JSONL。")
      }
      if !oldSessions.isEmpty {
        Text("\(oldSessions.count) 个在线会话仍用旧桥接，实时记录有缺口；等待自然加载，不强制重载。")
        ForEach(oldSessions, id: \.snapshot.identity) { session in Text(session.snapshot.display.name + " · " + (session.snapshot.display.model ?? "模型未知")) }
      }
      ForEach(usage.coverageReasons, id: \.self) { Text($0) }
      if usage.conflicts > 0 || usage.malformed > 0 { Text("冲突\(usage.conflicts)项、不可读\(usage.malformed)项；保留原记录，不覆盖旧值。") }
      if usage.pendingRecords > 0 { Text("\(usage.pendingRecords) 条记录待索引或需检查") }
      if let error = usage.error { Text("索引错误：" + error) }
      Text("原始时间UTC；按 " + usage.timeZoneID + " 本地日历分桶。" + utcRange)
      Text("reasoning已含在输出，cacheWrite1h已含在缓存写入，不再次相加；父owner累计和归属不明工具聚合不进时间账。缓存复用不是新增输入、套餐余额或费用。")
    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
  }
  private var shortWarning: String? {
    if usage.error != nil { return "索引暂不可用，已保留上次结果；详见记录详情。" }
    if usage.pendingRecords > 0 { return "\(usage.pendingRecords) 条待索引，当前为已知下界。" }
    if usage.conflicts > 0 || usage.malformed > 0 { return "记录有冲突或不可读项；原数据已保留。" }
    if !usage.totals.metric(metric).known { return usage.recordCount > 0 ? "所选字段未知，不以0补齐。" : "此范围/来源尚未采集，不代表零消费。" }
    if !oldSessions.isEmpty { return "\(oldSessions.count) 个旧桥接有实时覆盖缺口 · 详情已折叠" }
    return nil
  }
  private var updateLabel: String { usage.refreshedAt.map { "更新 " + $0.formatted(date: .omitted, time: .shortened) } ?? "尚未更新" }
  private var coverageStart: String { usage.collectedSince.map { model.usageOrigin.title + "已有记录从 " + dateText($0, format: "yyyy/M/d HH:mm") + " 起；未覆盖日期不补0" } ?? "所选来源尚无记录；未知消费不以0补齐" }
  private var rangeDates: String { dateText(usage.range.start, format: "yyyy/M/d") + " — " + dateText(usage.range.endDate, format: "yyyy/M/d") }
  private var utcRange: String {
    let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd HH:mm"
    return "UTC：[" + f.string(from: usage.range.start) + ", " + f.string(from: usage.range.end) + ")"
  }
  private var missingSummary: String {
    let missing = usage.buckets.filter { $0.state == .uncollected }.count, future = usage.buckets.filter { $0.state == .future }.count
    return "未采集\(missing)个桶；未来\(future)个桶尚未发生。未知不等于0。"
  }
  private func dateText(_ date: Date, format: String) -> String { let f = DateFormatter(); f.timeZone = usage.range.timeZone; f.dateFormat = format; return f.string(from: date) }
  private func dateLabel(_ date: Date) -> String { dateText(date, format: usage.range.hourly ? "HH:mm Z" : "M/d") }
  private func compact(_ number: Int64) -> String { Double(number).formatted(.number.notation(.compactName).precision(.fractionLength(0...2))) }
  private func value(_ v: UsageMetricValue) -> String { v.known ? (v.complete ? "" : "≥ ") + compact(v.value) : (usage.recordCount > 0 ? "未知" : "尚未采集") }
  private func exact(_ metric: UsageMetric, _ tokens: UsageTokenTotals) -> String { let v = tokens.metric(metric); return metric.title + " " + (v.known ? "\(v.value)，已记录下界" : "未知") }
  private func tokenField(_ label: String, _ number: Int64, known: Bool, complete: Bool, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(label) }.font(.caption).foregroundStyle(.secondary)
      Text(known ? (complete ? "" : "≥ ") + compact(number) : "未知").font(.system(size: 17, weight: .medium, design: .rounded)).monospacedDigit()
        .accessibilityLabel(label + (known ? " \(number)" : "未知"))
    }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
  }
}
