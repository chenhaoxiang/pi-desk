import Charts
import SwiftUI

struct UsageTrendChart: View {
  let usage: UsageAggregate
  private let labels = ["输入", "输出", "缓存读取", "缓存写入"]
  private let colors: [Color] = [.blue, .green, .purple, .orange]
  var body: some View {
    Chart {
      ForEach(usage.buckets.filter { $0.state == .data }) { bucket in
        marks(for: bucket, index: 0)
        marks(for: bucket, index: 1)
        marks(for: bucket, index: 2)
        marks(for: bucket, index: 3)
      }
    }
    .chartForegroundStyleScale(domain: labels, range: colors)
    .chartXScale(domain: usage.range.start...usage.range.end)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 7)) { value in
        AxisGridLine(); AxisTick()
        AxisValueLabel {
          if let date = value.as(Date.self) { Text(dateLabel(date)) }
        }
      }
    }
    .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName)) } }
    .environment(\.timeZone, usage.range.timeZone)
    .accessibilityLabel("所选时间已记录Token趋势，空白桶为尚未采集或未来时间")
  }
  @ChartContentBuilder private func marks(for bucket: UsageBucket, index: Int) -> some ChartContent {
    let values = [bucket.tokens.input, bucket.tokens.output, bucket.tokens.cacheRead, bucket.tokens.cacheWrite]
    let interval = usage.range.bucketEnd(bucket.day).timeIntervalSince(bucket.day)
    let start = bucket.day.addingTimeInterval(interval * 0.12)
    let end = bucket.day.addingTimeInterval(interval * 0.88)
    let lower = values.prefix(index).reduce(0.0) { $0 + Double($1) }
    let upper = lower + Double(values[index])
    RectangleMark(
      xStart: .value("开始", start), xEnd: .value("结束", end),
      yStart: .value("基线", lower), yEnd: .value("Token", upper)
    ).foregroundStyle(by: .value("类型", labels[index]))
      .accessibilityLabel(dateLabel(bucket.day) + " " + labels[index])
      .accessibilityValue("\(values[index]) Token，已记录下界")
  }
  private func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.timeZone = usage.range.timeZone
    formatter.dateFormat = usage.range.hourly ? "HH:mm" : "M/d"
    return formatter.string(from: date)
  }
}
