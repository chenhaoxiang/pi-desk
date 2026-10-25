# Spec Delta

## Purpose

让用户了解已接入Pi的Token消耗与真正需要关注的事项，并能识别统计来源、窗口、父子覆盖和未结算状态。该能力不通过扫描历史会话、额外模型轮询或自动回答来补数据，不让通知与显示故障改变已有任务或原问题处理。

## ADDED Requirements

### Requirement: Explicit usage scope and source

Pi Desk SHALL 为Token显示来源、统计范围、窗口及覆盖，区分接入后观察、owner原生会话累计和上下文占用，不把缺失数据当作0或全历史账单。

#### Scenario: TUI only exposes observed usage
- **WHEN** 当前桥接只能提供接入后的final usage
- **THEN** 单会话仍注明attachment-window及起点；只有持久化的稳定final时间记录参与Pi总用量，不拿该窗口快照冒充今日累计

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

### Requirement: Durable time aggregate usage

Pi Desk SHALL 默认展示跨所有已记录Pi会话的时间总用量，支持今日、含今日的近7天、本月与自定义起止日期，并提供趋势、input/output/cache四桶及模型分布。记录从启用采集起累计，不代表套餐余额、估价或真实账单。

#### Scenario: Local calendar crosses DST or month
- **WHEN** 用户在明确的本地IANA时区选择日期范围
- **THEN** 用日历日边界与内部半开区间归桶，DST/跨月/跨日保持精确，自定义结束日含整天，未来和未采集日期不伪装成零消费

#### Scenario: Cache reuse dominates recorded volume
- **WHEN** 缓存读取大于本次交互输入输出
- **THEN** 主页面分别显示交互Token(input+output)、缓存复用/写入和四桶记录总处理量；默认趋势使用交互口径，趋势/数据表/模型分布随同一选择切换，不把缓存隐藏或冒充新输入/账单

#### Scenario: Custom end precedes start
- **WHEN** 自定义结束日期早于开始日期
- **THEN** 不提交新查询，不将范围偷偷归一成另一天，保留旧有效结果并清楚要求修正日期；旧在途回调也不覆盖当前结果

#### Scenario: UI is closed and reopened
- **WHEN** 原Pi继续产生final usage而App退出或崩溃
- **THEN** bridge只入有界异步标量记录队列，App重开恢复持久总量，记录不依赖内存快照或同步handler磁盘I/O

#### Scenario: Duplicate or conflicting receipts arrive
- **WHEN** 重连/重载/多窗口带来重复或同ID内容冲突
- **THEN** 稳定receipt只累计一次，冲突不覆盖旧值并呈现覆盖缺口；不把父owner累计或归属不明工具聚合加到时间总账

#### Scenario: Old bridge or storage fails
- **WHEN** 来源不支持记录、字段缺失、文件/数据库损坏或队列/磁盘满
- **THEN** 保留已知量、旧库及明确错误/partial，不清空伪成功，不增加执行确认、不改变Pi工作

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

#### Scenario: User explicitly enables system notifications
- **WHEN** 用户主动点击开启系统通知
- **THEN** App调用标准系统授权接口，由用户在OS提示中决定；启动/状态事件不自动申请，不自动允许，拒绝或失败只影响表现且保持原Pi通知兜底

### Requirement: Evidence and private content separation

Pi Desk SHALL 分开呈现事实、规则结果、建议与unknown，保留来源/时间/适用head；观察和外发默认不包含管理文本、原始对话、命令或凭据。

#### Scenario: CI summary lacks current binding
- **WHEN** 只能获得旧head、Agent自报或缺少来源的成功状态
- **THEN** 不展示为当前测试、合并或部署已验证

#### Scenario: User submits a management message
- **WHEN** 用户主动向原会话提交要求
- **THEN** 内容只走目标管理路径，不顺带进入telemetry、历史数据库或外发推送
