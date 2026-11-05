import PiDeskCore
import SwiftUI

struct QuestionWorkContextView: View {
  let inputs: [InputNotice]
  var omitted = 0
  var body: some View {
    let questions = inputs.filter { $0.kind == "question" }
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(questions.prefix(4))) { input in
        if let link = input.question {
          VStack(alignment: .leading, spacing: 3) {
            Text(link.title).font(.caption.weight(.medium))
            if let work = link.workRef { Text(work.owner).font(.caption2).foregroundStyle(.secondary) }
            if let phase = link.workPhase { Text("原工作阶段：" + phase).font(.caption2).foregroundStyle(.secondary) }
          }
        }
      }
      if questions.contains(where: { $0.question != nil }) {
        Text("工作关联由原调用方声明，不认证归属；具体问题仍在原会话，标为已读不等于回答或授权。").font(.caption2).foregroundStyle(.secondary)
      }
      if questions.count > 4 { Text("另有 \(questions.count - 4) 个输入请求未在此展开").font(.caption2).foregroundStyle(.secondary) }
      if omitted > 0 { Text("原快照另有 \(omitted) 个输入请求因显示预算省略，请回原会话查看。").font(.caption2).foregroundStyle(.secondary) }
    }
  }
}
