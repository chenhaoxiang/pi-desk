# Design

## 唯一事实与owner

Pi CLI/Runtime及原生owner保持任务/执行/验收事实与写入权威，Desk只消费。治理SSOT复用pi-vista的docs/pi-continuum.md、work-result-continuity-design.md与adapter-pi已有work_ref/binding/result/handoff接口；本仓只维护消费wire和UI，不再创建平行Pi工作状态机。治理负责人维护原owner producer/结果验收/恢复；Desk维护展示与精确管理请求。

## 首批：原生Todo→同源工作台

在既有Snapshot加入可选todo投影：source=pi.todo、scope、observerSeq（只观测顺序）、observedAt、已哈希的toolCallId、coverage、状态计数、omitted、有限任务列表。成功的todo TaskDetails已含完整当前任务集合；只允许id/subject/activeForm/status/blockedBy/owner，不采集params/description/metadata/工具正文或思考。没有当前snapshot RPC，不另import getTodos实例，不读branch或历史文件；启动not-observed，不用空数组宣称没有任务。

扫描最多512项，传输最多32项且todo预算8KiB，任务文本按UTF8有界、疑似凭据和绝对路径占位，不外发AI。真实dependencies按原ID展示；缺失/deleted依赖继续未解决，只计算本session/scope关系，不从pending推断等待人或CI。counts只表示原计划，completed不成为verified/delivered。省略与文本缩减标partial。

工具开始绑定当时scope，晚到结束不得写到新branch/session；clear更新scope，session_tree/session_compact失效旧投影。旧bridge无字段UI显示unavailable；断线标stale保留最后快照但不混入当前计数。重连重新读取bridge当前内存快照，不触发Todo工具、不扫描历史、不启动模型。App不把Todo正文写入usage SQLite或本机权威库。

## UI与管理

新增“工作总览”，保留会话/Token/重要事项/AI/健康/设置。新安装默认工作总览，既有页面偏好尊重保留。首批按原生会话展示当前任务/步骤、计划已完成数、依赖卡点、输入等待和来源覆盖；同名不合并，产品/work归属未提供明确显示。工作总览的依赖提示是从Pi blockedBy确定性派生，不冒充owner nextAction；无producer的结果/下一步不补造。已有输入生命周期才进“需要你输入”，未采集任务不伪装正常。

操作复用准确原会话打开、详情和follow-up/steer；不新增Todo mutation、默认Agent总结、审批或轮询。日后按已交付owner能力加入回答/优先级/工作绑定写入口，必须回原owner并读回，不在Desk乐观修改事实。

## 后续与验收

W1当前任务清单及coverage可用；W2消费已交付work/result/attention/问题引用，按显式映射归产品/工作项；W3一个低风险自然任务覆盖等待解除→续接→owner验收→交付→Desk同步；W4根据有限自然样本扩展自主升级/优化，保持原权限/预算/安全切换与回退。关闭Desk不停止Pi；消息送达/Todo完成/进程结束/源码安装等不能互相推导。

Swift/TS黄金fixture、branch/clear/迟到/失败/secret/超量负例、SDK原生Todo工具事件、真实UDS跨语言与UI纯派生检查，验证无新模型/权限/工具/确认。已存在性能优化继续保留，不因新页恢复热路径重复计算。
