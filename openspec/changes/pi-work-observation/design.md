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

## W2：原owner工作结果与交接

复用Vista既有PiWorkBinding/PiResultConsumption/PiWorkHandoffObservation；Desk仅在Snapshot可选governance中保存有界消费副本，不产生验收、签名或执行许可。Vista owner维护同进程内存-only出口；Desk不另实例化工厂、不监听请求后重复调用readOwner。请求/回包按准确hostSessionId、requestId和本次consumer范围绑定，observerEpoch/seq隔离旧响应；查询不能刷新原结果的观察时间或把历史记录变成当前证明。

结果只按显式owner/kind/key归组，完整stage/run/session/revision/head仍逐条显示；reporting session不是所有业务任务的owner。subagent-output-available仅“产物可用”，source-shared-delivery仅“源码阶段已交付”，其他stage保留原标签与限定范围。保留原交接accepted/unresolved/blocker引用与nextAction；wait/reconcile不自动变成用户审批。没有product/goal/人工问题producer就继续明确未提供。

work结果与派生分组只有有界内存缓存，store替换即失效；不写用量库或外发AI。桥接中给治理投影预留至多6KiB并同步压缩原展示行预算，保留整体64KiB上限。为维持精确引用只省略整个结果，不裁断binding或改造owner结果。

## 原生问题工作关联首切片

不重做问题UI、不新建问题库、不增加回答API。rpiv-ask-user-question owner保留pi:input-required v1，并在实际custom UI opened/answer-received/closed时可选发布pi:work-question:v1；Desk只附InputNotice.question（declared/unbound/unavailable、PiWorkRef、stage、owner epoch/seq/time）。声明不是认证，未知关联不阻止原生提问。任何正文/选项/答案/私有路径都不进入该投影或用量存储。

v1的id与新事件toolCallId原字符串对应；Desk将完整opaque id散列为单一输入标识，兼容native组合/编号而不截断，附关联不改已读key、不重复提醒。新事件核原session/epoch/seq，terminal不会创建新输入；原v1 end继续关闭等待，避免可选元数据故障留下假等待。v1本身无epoch，不能据此宣称已解决跨实例同ID重用/replace/revoke/partial/fresh-owner全部问题；这部分仍由原owner后续合同负责。

首片只在旧输入卡片/详情/工作总览显示原声明的关联，具体问题仍回准确原入口处理。“已读”仍只改本机提醒，answer-received不是应用决定或授予权限。原owner源码与最终安装件分层验真，不把候选SDK fixture成功写成全活跃会话已加载。

## 后续与验收

W1当前任务清单及coverage可用；W2消费已交付work/result/attention/问题引用，按显式映射归产品/工作项；W3一个低风险自然任务覆盖等待解除→续接→owner验收→交付→Desk同步；W4根据有限自然样本扩展自主升级/优化，保持原权限/预算/安全切换与回退。关闭Desk不停止Pi；消息送达/Todo完成/进程结束/源码安装等不能互相推导。

Swift/TS黄金fixture、branch/clear/迟到/失败/secret/超量负例、SDK原生Todo工具事件、真实UDS跨语言与UI纯派生检查，验证无新模型/权限/工具/确认。已存在性能优化继续保留，不因新页恢复热路径重复计算。
