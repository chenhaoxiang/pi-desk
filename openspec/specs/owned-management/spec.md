# owned-management Specification

## Purpose
使用户能够从统一界面对原Pi会话、子任务和已有计划发起准确的管理动作，并继续使用原AI与CLI入口。管理由原组件执行和验证，不复制执行器、任务库或权限规则，也不把界面在线和人工逐项批准变成自动化前置。

## Requirements

### Requirement: Owner backed capabilities

Pi Desk SHALL 仅对当前对象公开原owner已声明并实际接线的动作；不提供任意shell、任意工具执行或内部状态文件编辑，不替代原权限与管理路径。

#### Scenario: Owner lacks an operation
- **WHEN** owner不支持某项恢复或计划管理动作
- **THEN** 仅该动作显示不可用及原因，原Pi任务与其既有工具仍可继续使用

#### Scenario: Supported management action
- **WHEN** 用户在准确目标上提交已支持的动作
- **THEN** 请求进入原owner接口并按原规则处理，不增加第二审批者或另建同任务

### Requirement: Native message delivery modes

Pi Desk SHALL 对追加与纠偏使用目标Pi的原生follow-up或steer语义，不通过模拟终端按键或先停止再重启来代替。

#### Scenario: Append while a tool runs
- **WHEN** 用户对正在运行的会话提交follow-up
- **THEN** 当前工具继续，消息按原生后续路径处理，无关联收据只显示已请求，证实后才显示排队

#### Scenario: Steer a selected run
- **WHEN** 用户对准确会话或owner子运行发出纠偏
- **THEN** 按原owner支持的边界递送，不将普通状态通知转成新模型指令

### Requirement: Separate stop and pause semantics

Pi Desk SHALL 区分中止当前回合、停止子任务、暂停未来计划触发及静音提醒，并如实显示各自影响范围和终态。

#### Scenario: Pause a schedule with active work
- **WHEN** 用户暂停一个仍有活动运行的计划
- **THEN** 后续触发按owner规则暂停，当前运行不被冒称已经停止

#### Scenario: Stop request accepted
- **WHEN** 子任务owner仅确认stopping或已收到停止请求
- **THEN** 界面显示请求状态，直到owner提供实际终态才显示已停止

#### Scenario: Abort current session turn
- **WHEN** 用户请求中止当前回合
- **THEN** 不声称所有独立子任务、排队消息和外部副作用均已撤销，其他会话不受影响

### Requirement: Exact target and bounded duplicate handling

Pi Desk SHALL 绑定请求、会话runtime及owner运行引用，拒绝过期或错误对象；丢回复、重连或重启后不得盲目重复派发可能产生副作用的动作。

#### Scenario: Lost action reply
- **WHEN** 动作可能已执行但客户端没有收到回复
- **THEN** 显示unknown，有准确owner引用时查询；缺引用仍保留unknown，不因缺回复重新发送同一业务动作

#### Scenario: Same request duplicated within a live runtime
- **WHEN** 同一准确requestId在当前有界去重记录中再次出现
- **THEN** 返回原受理结果而非重复执行，不宣称跨重启的exactly-once保证

#### Scenario: Runtime epoch changed
- **WHEN** 用户界面仍持有旧epoch的运行卡片
- **THEN** 对该对象的控制被拒绝并要求刷新，不转发到新会话或同名对象

### Requirement: Owner qualified recovery and schedules

Pi Desk SHALL 由原owner验证恢复资格、运行归属和计划状态，保留不同owner的命名空间；恢复失败不得隐式新建运行或修改任务存储。

#### Scenario: Recovery is not eligible
- **WHEN** owner报告原运行仍活跃、租约冲突或恢复证据不足
- **THEN** 保留原拒绝/unknown状态，不从头重跑以制造恢复成功

#### Scenario: Same named schedules from two owners
- **WHEN** 两个owner存在相同名称的计划
- **THEN** 分别显示和管理，不把它们合并或向另一owner发动作

### Requirement: No new manual execution gate

Pi Desk SHALL 让原本授权内的自动检查、重试、子任务回传和交付继续执行，不因重要事项、已读状态或界面按钮引入逐项确认。

#### Scenario: User ignores a normal result card
- **WHEN** 用户没有阅读或关闭一条结果提醒
- **THEN** 原自动化按原条件继续，未读不阻止后续任务

#### Scenario: Actual owner rule requires a decision
- **WHEN** 原系统本来就要求用户作出必要决定
- **THEN** 界面可提示并定位该决定，但不能新增或绕过原规则
