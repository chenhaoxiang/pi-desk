# Spec Delta

## Purpose

让用户了解已接入Pi的Token消耗与真正需要关注的事项，并能识别统计来源、窗口、父子覆盖和未结算状态。该能力不通过扫描历史会话、额外模型轮询或自动回答来补数据，不让通知与显示故障改变已有任务或原问题处理。

## ADDED Requirements

### Requirement: Explicit usage scope and source

Pi Desk SHALL 为Token显示来源、统计范围、窗口及覆盖，区分接入后观察、owner原生会话累计和上下文占用，不把缺失数据当作0或全历史账单。

#### Scenario: TUI only exposes observed usage
- **WHEN** 当前桥接只能提供接入后的final usage
- **THEN** 显示attachment-window及起点，不标成整个会话或今日累计

#### Scenario: Context occupancy is available
- **WHEN** Pi只提供当前上下文占用估计
- **THEN** 单独展示该估计，不计入已消耗Token或费用总数

#### Scenario: Usage or cost is unknown
- **WHEN** provider/owner未提供可靠用量或价格
- **THEN** 对应项显示unknown或隐藏金额，不推断免费或伪造费用

### Requirement: No historical session discovery

Pi Desk SHALL 从已接入宿主的usage元数据或原owner定向当前统计取数，不扫描、导入或解析历史会话目录和原始会话文件。

#### Scenario: Current owner reports associated run totals
- **WHEN** 原owner读取当前会话关联运行产物并返回统计结果
- **THEN** Pi Desk只消费带scope的结果，不新增广泛历史发现，不把这项统计变成新的批准流程

#### Scenario: Previous sessions exist on disk
- **WHEN** 本机存在未接入的旧会话与JSONL
- **THEN** 它们不被发现、导入或用来填补统计图表

### Requirement: Single settlement and parent child accounting

Pi Desk SHALL 不重复累加流式累计值、同一usage重放或已包含的子任务；跨范围或父子归属不明时保留partial，不展示精确全局合计。

#### Scenario: Stream update and final message repeat a cumulative value
- **WHEN** 同一消费记录出现多个流式快照及final结算
- **THEN** 只结算一次，不按帧增加消耗

#### Scenario: Child is displayed independently and under a parent
- **WHEN** 同一子运行同时出现在独立会话卡和父owner报告中
- **THEN** 两处可关联展示，但统计汇总不重复计入

#### Scenario: Runtime reload creates a new observation window
- **WHEN** 扩展重载且不能恢复完整统计归属
- **THEN** 明确新窗口/覆盖，不能把不相容窗口拼成原生完整累计

### Requirement: Actual attention without extra work

Pi Desk SHALL 根据实际待输入生命周期和有来源的任务状态呈现重要事项，不把idle、无输出或每个工具错误当需人工决策，不为监控持续调用模型。

#### Scenario: Native automatic recovery is in progress
- **WHEN** 原Pi正在重试或恢复
- **THEN** 显示自动恢复而不要求点击继续，不增加模型判断回合

#### Scenario: Custom UI ownership is unknown
- **WHEN** 只观察到generic custom UI而没有准确问题归属
- **THEN** 不伪造问题内容或假设另一个ask工具已要求用户回答

### Requirement: Notification and input independence

Pi Desk SHALL 让已读、静音、关闭提醒和通知失败只影响表现，不代答、取消原问题或重跑业务；无法可靠接管时保留原通知兜底。

#### Scenario: User dismisses an input reminder
- **WHEN** 用户关闭或静音提醒
- **THEN** 原Pi问题仍可按原流程处理，提醒动作不等于同意、拒绝或回答

#### Scenario: Notification transport fails
- **WHEN** 显示或通知交付失败
- **THEN** 不禁用已授权执行、不重新执行任务，也不关闭仍有效的原通知路径

### Requirement: Evidence and private content separation

Pi Desk SHALL 分开呈现事实、规则结果、建议与unknown，保留来源/时间/适用head；观察和外发默认不包含管理文本、原始对话、命令或凭据。

#### Scenario: CI summary lacks current binding
- **WHEN** 只能获得旧head、Agent自报或缺少来源的成功状态
- **THEN** 不展示为当前测试、合并或部署已验证

#### Scenario: User submits a management message
- **WHEN** 用户主动向原会话提交要求
- **THEN** 内容只走目标管理路径，不顺带进入telemetry、历史数据库或外发推送
