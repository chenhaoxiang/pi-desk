---
doc_type: reference
project: workspace
owner_repository: chenhaoxiang/pi-desk
product_line: pi-desk
release_scope: 接口基线快照与本地实现接线；非全模式认证
status: active
truth_mode: maintained
created: 2026-10-24
verified: 2026-10-24
verification_scope: 指定公开源码基线、隔离Pi1.4与Subagents0.80及Schedule源码seam；非全局热加载/业务环境
---

# 接口核实与集成矩阵

## 1. 证据级别

下列SHA是本次读取的本地源码基线，不代表所有远端一直停在这些提交，也不认证旧会话已加载它们。五个Pi相关仓在2026-10-24经GitHub元数据确认为公开仓。Pi Desk自身远端是public、非fork、默认main且无提交；此次方案只在本地专属worktree。

| 公开项目 | 本次读取SHA | 源码版本 |
|---|---|---|
| chenhaoxiang/pi | `aabcd6e46d5d6f80338f41c41554d1dea5e7eea7` | coding-agent `1.4.0-fork.1` |
| chenhaoxiang/pi-subagents | `7ff515bf5fa8873a678c444885903ba1eeb9f061` | `0.80.0-fork.1` |
| chenhaoxiang/pi-intercom | `8953e0689b05368295540692525d688ad57494bd` | `0.18.0-fork.3` |
| chenhaoxiang/pi-schedule-prompt | `6ac872f0b090fbcbc0708e7ceff91d7a5506a3b5` | `0.4.1-fork.4` |
| chenhaoxiang/pi-vista | `0295559fef2d00dddd1a706731c04329108d3ffd` | 架构/观察边界参考，不新增运行依赖 |
| wxtsky/CodeIsland | `422036e320bdec43e53b67a9fc9ab67f13ae6bce` | `v1.0.40`，前轮获取的公开快照 |

## 2. 能力与缺口

下表保留架构时的源合同/设计说明；不能把表中版本当作当前所有会话已加载。已实现和实测接线另见第6节。owner源码改动只发生在明确授权的独立候选树，不安装到业务会话。

| 目标 | 已核实接口/事实 | Pi Desk设计及限制 |
|---|---|---|
| 生命周期 | `session_start/shutdown`、`agent_settled`、`model_select`、`tool_execution_start/end` | 需bridge；不从agent_end推断稳定结束，不用tool_call gate做观察；session header createdAt只投影标量，旧bridge缺失为unknown |
| 直接消息 | `pi.sendUserMessage(content,{deliverAs:'steer'|'followUp'})`返回void | 需bridge；提交不等于模型接收/任务完成，不承诺native durable requestId |
| 中止当前回合 | `ctx.abort():void` | 只对当前身份/epoch；读后续生命周期，不等同清队列/停计划/停所有孩子 |
| 独立RPC宿主 | `get_state`、`get_session_stats`、`prompt`、`abort`等 | 只能复用已有owner宿主，不把所有TUI迁成RPC，不新开同session竞争writer |
| 扩展统计 | ExtensionContext有`getContextUsage`但无`getSessionStats` | 会话次级报告保持接入窗口；时间总览使用已接入final增量专用持久记录，不拿owner累计反推日期，不访问内部私有实例 |
| 稳定usage来源 | `turn_end`提供`messageEntryId/toolResultEntryIds`；原生SessionStats累计usage、compaction、summary及工具usage | 用标量、稳定引用去重；不直接复制全量messages/entries到App |
| Subagents查询与管理 | `subagents:rpc:v1:request`与reply channel；ping/status/steer/interrupt/stop/resume/cost/manage | 需bridge；在原owner会话内调用，进程内总线不是可由Swift直接调用的网络端点 |
| 子任务能力发现 | ping.capabilities：managementActions、resume、fleetStatus、nonRecoveringSteer等 | 每runtime查验；未知/旧版仅禁相关UI动作，不升级/重启原会话 |
| 子任务标识 | Fleet是展示投影；asyncSnapshot另有真实run id | 不把display key解析成runId，不跨owner/epoch发动作 |
| 子任务统计 | cost返回parent/children/childTotal/total、unresolvedAsyncChildren，读取当前分支/关联产物 | 在settled/完成或显式刷新调用，非周期目录扫描；partial保留为下界 |
| Subagents计划 | manage allowlist含schedule.list/show/history/pause/resume/run/delete | 带owner命名空间；history是原计划执行元数据，不新增会话历史扫描器 |
| Intercom presence | extension注册channel的listSessions与presence事件 | 可以复用现有presence，不依赖它给所有Pi自动授权；不将未知peer自动纳管 |
| Intercom出站v1 | outbox字段为requestId/extensionId/name/to/message，无wake或mode | 不把它当精确steer/follow-up接口；自身会话走直接Pi API，跨peer能力后续按owner实现 |
| Schedule Prompt | schedule_prompt工具有管理动作；`schedule:event:v1`只负责事件触发，不是管理接口 | 不向事件负载塞prompt/管理命令。通用在线CRUD需owner seam，不直接读写schedule-prompts.json |
| Schedule常驻宿主 | 文档提供固定run/status/stop/plist，回环控制仅鉴权status/stop | 不能凭配置文件存在声称服务运行；不假造在线新建/启用/暂停端点 |
| 待输入 | `ui_prompt_start/end`；question producer提供`pi:input-required`内容无关生命周期 | 先提醒+跳转，generic custom不猜来源，不拦工具制造新等待，不自动代答 |
| Guard/Gate/CI | 各owner只读状态/受限观察，可有head/freshness | 当前没有通用Pi Desk producer；先明示未接入，不读raw审计或把自报passed当权威 |
| 现有服务控制台 | 用户显式配置的精确页面/受限API | 首版打开原管理页；不复制私有源码、机器地址、路径、scope或凭据进公开仓 |
| 原会话定位 | Herdr精确pane；本轮补Terminal.app唯一TTY/TERM_SESSION_ID route，tmux仅在一次性client_tty可核对时转外层TTY | count非1/Automation拒绝/旧bridge缺route显示不可定位；不按cwd/名称猜，不对活跃session自动`pi --session`开第二writer |
| Pi原生设置 | user `<agentDir>/settings.json`按Pi settings schema白名单读写；project `.pi/settings.json`只读来源提示 | PiSettingsStore兼容`.lock`、revision/hash CAS、owner-only backup、atomic rename/readback；auth/models/mcp/resources/proxy/trust/permissions/defaultModel/defaultTools排除 |

## 3. 原生模式差异

[Pi CLI Integration](https://github.com/chenhaoxiang/pi/blob/aabcd6e46d5d6f80338f41c41554d1dea5e7eea7/packages/coding-agent/docs/cli-integration.md)说明各CLI模式复用主能力，但TUI-only交互在RPC受限；[RPC Extension UI](https://github.com/chenhaoxiang/pi/blob/aabcd6e46d5d6f80338f41c41554d1dea5e7eea7/packages/coding-agent/docs/rpc-extension-ui.md)明确`custom()`不可按TUI使用。裸SDK的资源/default builtins也须单独配置。Pi Desk不靠统一迁移消除这些差异，而使用原宿主薄适配。

[RPC文档](https://github.com/chenhaoxiang/pi/blob/aabcd6e46d5d6f80338f41c41554d1dea5e7eea7/packages/coding-agent/docs/rpc.md)要求持续读取stdout，否则背压可拖住Pi。现有RPC宿主仍负责读取，不让UI在线状态成为该读取责任的前置。

## 4. CodeIsland取舍

[Pi资源](https://github.com/wxtsky/CodeIsland/blob/422036e320bdec43e53b67a9fc9ab67f13ae6bce/Sources/CodeIsland/Resources/codeisland-pi.ts)包含危险Bash的blocking PermissionRequest、额外allow标记、ask工具专门映射和await socket发送；不带入。其agent_end→Stop也不直接作为我们最终完成语义。

[HookServer](https://github.com/wxtsky/CodeIsland/blob/422036e320bdec43e53b67a9fc9ab67f13ae6bce/Sources/CodeIsland/HookServer.swift)的可选Webhook含raw event；[AppDelegate](https://github.com/wxtsky/CodeIsland/blob/422036e320bdec43e53b67a9fc9ab67f13ae6bce/Sources/CodeIsland/AppDelegate.swift)正常启动会安装/修复hooks。以上都不作为Pi Desk的默认机制。

顶栏、屏幕几何、窗口焦点、Herdr跳转可参考，但大视图依赖AppState/Settings，不能视作现成独立库。首版选择系统API小型原创外壳，局部源码复用须逐段记录MIT归属。[上游许可证](https://github.com/wxtsky/CodeIsland/blob/422036e320bdec43e53b67a9fc9ab67f13ae6bce/LICENSE)不授予其品牌、签名或更新身份。

## 5. 实施时的再核验

只补受影响的版本/能力核验，不每次全仓重读。最小组合为维护Pi1.4基线、Subagents0.80基线、缺少Subagents和缺能力旧owner；Schedule/Intercom能力独立适配。源码、打包加载、真实TUI、多会话/子任务、原生通知和长时间可靠性分别测试，不将本表称已兼容或已安装。

## 6. 当前本地接线（非热加载声明）

`packages/desk-bridge/src/` 已实现上述native/UDS/Subagents路径。隔离faux-native组合实际加载 Pi1.4.0-fork.1 和 Subagents0.80.0-fork.1；Workflow后台孩子使用定向status返回的真实child runId，前台Fleet仍是display-only，不猜ID。stop仅回执stopping，收到owner terminal proof才报告终态；resume保留owner拒绝/资格。

Schedule在线管理seam位于该owner的本地 `249a8fa8529c4ac988f1b5a4845426ce6aa2dd79`（含 `85c58cd`），原0.4.1-fork.4旧运行不因此获得能力。Intercom v1 outbox未改、不用于精确递送；管理已接入会话走本身native API。原生输入事件可用，question producer按其实际加载能力出现；Terminal Automation/Herdr实机跳转、VoiceOver和OS通知交付仍unknown。详见[实施记录](implementation-plan.md#6-本地实施与证据层级)。

公开参考：[Pi扩展声明](https://github.com/chenhaoxiang/pi/blob/aabcd6e46d5d6f80338f41c41554d1dea5e7eea7/packages/coding-agent/src/core/extensions/types.ts)、[Subagents公共合同](https://github.com/chenhaoxiang/pi-subagents/blob/7ff515bf5fa8873a678c444885903ba1eeb9f061/docs/extension-api.md)、[Intercom扩展合同](https://github.com/chenhaoxiang/pi-intercom/blob/8953e0689b05368295540692525d688ad57494bd/extension-api.ts)、[Schedule常驻合同](https://github.com/chenhaoxiang/pi-schedule-prompt/blob/6ac872f0b090fbcbc0708e7ceff91d7a5506a3b5/docs/durable-supervisor.md)、[Vista非授权边界](https://github.com/chenhaoxiang/pi-vista/blob/0295559fef2d00dddd1a706731c04329108d3ffd/docs/pi-continuum.md)。
