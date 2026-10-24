# Spec Delta

## Purpose

让用户在原生客户端中了解明确接入的在线Pi会话、当前运行与子任务关系，同时保持原有自动执行、资源与规则不变。客户端仅增加可选展示和管理入口，不通过历史发现、人工关卡或对运行宿主的接管来获得可视化。

## ADDED Requirements

### Requirement: Explicit live session enrollment

Pi Desk SHALL 仅展示主动接入并提供当前身份的Pi会话，不扫描进程、终端正文或历史会话目录来发现对象。

#### Scenario: No enrolled session
- **WHEN** App已启动但没有Pi主动注册
- **THEN** 显示尚无已接入会话，不发现旧JSONL或进程以填充列表

#### Scenario: Existing TUI session enrolls
- **WHEN** 既有TUI会话按其正常加载路径启用桥接
- **THEN** 客户端接收当前快照，不强制切换为RPC、改变工具或重启其他会话

### Requirement: Runtime scoped identity

Pi Desk SHALL 按准确会话身份和runtime代际隔离显示与管理对象，不以名称、cwd、PID、tty或展示key替代控制身份。

#### Scenario: Runtime replacement
- **WHEN** 同一会话reload后产生新runtime代际
- **THEN** 旧代际管理请求与晚到回复不能作用于新runtime，能力重新核实

#### Scenario: Shared working directory
- **WHEN** 两个Pi会话使用相同cwd或名称
- **THEN** 状态和管理目标仍按独立身份隔离，不相互覆盖

### Requirement: Execution independent of the client

Pi Desk SHALL 在未启动、断联、退出、崩溃或更新时保持原Pi及其现有自动化独立运行；观察接线 MUST NOT 增加人工确认、模型请求或执行前置。

#### Scenario: Client disappears during work
- **WHEN** App在工具、自动重试或子任务运行期间被终止
- **THEN** 原Pi不因App消失被abort或shutdown，计划、原生续行和子任务回传继续按原行为执行

#### Scenario: Baseline automation comparison
- **WHEN** 相同固定任务在桥接关闭和开启两种条件下运行
- **THEN** 原模型/思考档/工具/资源/规则不被修改，展示新增模型调用与人工确认均为0

### Requirement: Bounded nonblocking observation

Pi Desk SHALL 让观察处理不等待界面或传输，限制队列、帧及内存；过载只降级显示并显式标记不完整，不改变工具输入、结果或续行决定。

#### Scenario: Slow client and saturated queue
- **WHEN** 客户端停止读取且观察事件持续产生
- **THEN** 原工具不等待客户端，内存有界，显示更新可合并或丢弃并报告drop/过期

#### Scenario: Malformed event
- **WHEN** 连接收到超长或非法记录
- **THEN** 仅该连接/记录被拒绝且不回显敏感正文，Pi原执行不受影响

### Requirement: Truthful lifecycle and coverage

Pi Desk SHALL 分开显示连接、执行、关注和验证状态，不把agent_end、无输出、已受理或单工具成功推断为全部完成。

#### Scenario: Low-level run ends before continuation
- **WHEN** agent_end之后还有自动重试、压缩、队列消息或owner关联子任务
- **THEN** 界面不提前宣布整项工作已完成，也不要求用户点击继续

#### Scenario: Connection becomes stale
- **WHEN** 最新可用状态已过期或连接丢失
- **THEN** 保留更新时间并显示stale/unknown，不把断联标成任务失败或已停止

### Requirement: Local metadata and accurate navigation

Pi Desk SHALL 默认仅收集必要安全显示元数据，并只通过核实的当前对象路由跳转；不将原始prompt、命令参数、输出、思考或凭据带入观察/外发数据。

#### Scenario: Synthetic secret in raw payload
- **WHEN** 工具参数或结果包含合成敏感值
- **THEN** 该原始字段不进入观察wire、日志或推送

#### Scenario: Exact terminal route is unavailable
- **WHEN** 对应终端或Herdr路由无效
- **THEN** 显示跳转失败，不激活另一个会话冒充成功
