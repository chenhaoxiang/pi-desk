---
doc_type: plan
project: workspace
owner_repository: chenhaoxiang/pi-desk
product_line: pi-desk
release_scope: 首版分阶段实施候选；非排期或发布承诺
status: draft
truth_mode: maintained
created: 2026-10-24
verified: 2026-10-24
verification_scope: 对照用户范围、公开接口和架构拆分；无业务实现或运行验收
---

# 分阶段实施方案

## 1. 当前交付与下一次实施起点

本轮只完成仓库拉取、需求/架构/交互/实施方案候选、单一OpenSpec Change与文档检查。无业务代码、可安装App、全局扩展接入、真实Pi控制、发布或部署。远端空main不能普通创建PR；本地规划分支保全成果，不因此直推main或改变保护。

未来实施沿[本Change任务](../openspec/changes/pi-desk-v0-1/tasks.md)推进。阶段任务是依赖与验收划分，不是逐项人工审批流程；用户后续授权的实际范围决定可连续实施到哪一步。新增运行/生产/账号/预算边界按真实授权判断，不靠文档猜测。

## 2. 阶段与依赖

| 阶段 | 最小成果 | 依赖与完成依据 |
|---|---|---|
| M0 合同与工程骨架 | SPM原生targets、TS bridge包、wire fixtures、版本/capability合同、无敏感CI | 本规划；Swift构建/Node类型检查、双端同fixture及负例；不加载真实凭据 |
| M1 在线可视化纵切 | 显式接入两个会话、当前快照、顶栏/窗口、准确状态/跳转、接入窗口usage | M0；不扫描文件/进程、App崩溃不阻塞、重复/乱序/旧epoch与无刘海验证 |
| M2 原生管理闭环 | 直接Pi follow-up/steer/abort-current，Subagents状态/stop/resume，操作回执 | M1；有真实faux-native owner闭环，目标/epoch/能力校验、丢回复不重放、停止终态与独立任务持续运行 |
| M3 统计与现有计划 | owner cost投影、父子不重复、partial；Subagents计划与Schedule薄接口 | M2；固定会话/运行统计、fork/reload/cache/compaction/nested usage负例；两个owner不混同；缺接口如实降级 |
| M4 注意事项与治理入口 | 原输入生命周期提醒、通知去重/兜底、治理/Gate/CI安全摘要、现有管理页链接 | M2，可与M3独立推进；不新增judge/轮询模型，原通知/输入不被接管失败吞掉，来源/head/freshness正确 |
| M5 完整首版验收 | 模式/多会话/子任务兼容矩阵、自动化不退化、最小打包与回退 | M1–M4；离线fixture+隔离原生SDK+授权范围内真实本机验证分别记录 |

M1仅是观察纵切，不能作为完整首版交付。M2开始必须有真正管理能力，不能用“打开终端自己处理”替代所有管理。M3/M4的可选外部来源未配置不阻塞核心，但其已承诺管理能力缺口要在v0.1验收前解决或明确由用户调整范围，不能自行删减。

## 3. 每阶段实施要点

### M0

- 选最小系统依赖，不搬CodeIsland项目。双端schema用synthetic固定记录，测试断行、半包、超长帧、unknown字段、schema主版本不匹配。
- 建立Bridge不注册新模型工具、不改变active tools/prompt的断言；同一固定宿主版本比较已加载资源。
- CI仅执行合成测试、build/typecheck、泄漏检查；macOS job、平台权限及runner可用性在仓库实际接入时核实，不调用模型、不安装全局扩展。Linux能测TS/纯协议不替代原生Mac证明。

### M1

- Extension资源从session_start建立，session_shutdown幂等释放。socket/ps/git不进入同步生命周期handler。
- 使用原生state/events与owner关系，覆盖进程内多个会话和异步/前台孩子。无owner关系不猜测。
- 文本、计数、模型等投影单独有界；不传raw prompt/工具参数/输出。
- 顶栏优先于刘海特效；无刘海、外接屏、缩放与减少动态效果都有可用入口。

### M2

- 管理面是闭集动作，无任意工具/shell入口。确保原生发送与ctx.abort在真实上下文可安全使用；旧ctx失效返回定向错误，不重启会话修复UI。
- App点击只提交一次；进程内短期去重与owner引用查询不能冒充持久exactly-once。UI重启后unknown不盲目重发。
- 原生abort-current与run.stop分开，后者仅按owner支持证明结束。需要清队列或停整个任务组时不能偷偷扩大action语义。

### M3

- 主动接入的TUI统计窗口与owner原生累计分别展示。原owner读取其当前关联产物属于统计来源，不是Pi Desk历史扫描；App自己不读原文件。
- 固定双端统计fixture包含：流式累计只结算一次、同message重放、cache字段、compaction/summary、嵌套工具usage、fork继承、父子双卡、未结算与恢复后新窗口。
- Subagents已有API先接；Schedule Prompt在线管理seam若仍缺，在该owner的独立worktree补最薄公共接口与测试，不在Pi Desk直接修改状态文件。跨owner源码变更不属于本轮规划。
- 精确跨peer消息模式如果需要，先修现有Intercom接线缺口，不用旧outbox字段猜wake/steer。

### M4

- 只监听真实等待输入区间，generic custom无法归属时不显示假问题。首版不接管回答，原TUI与自动决策不变。
- 对原producer有可靠事件ID的通知才做精确去重；接管失败继续原兜底，不能统一静默全部通知来减少重复。
- Guard/Gate/CI只消费明确当前owner的安全摘要。先实现合成reader；真实producer缺口要明确，不能扫描私有事件和原始日志充数。
- 管理系统以用户本机配置的精确链接开始，状态/受限API后续只按具体需要接入，不复制整个控制台或权限系统。

### M5

- 同一输入、模型、工具、原规则、资源比较关闭桥接/接入桥接的执行轨迹。
- 冻结已测候选源与fixtures，记录UI、bridge、Pi和各owner实际加载版本；磁盘版本不代表进程热加载。
- 原生本机验收只操作指定隔离会话和owned进程，不强制reload业务会话、不伪造成功证明。
- 打包后先旁路候选与回退；签名、公证、更新源、安装启用及发布各有实际结果，源码完成不能替代它们。

## 4. 自动化不退化验收矩阵

| 编号 | 故障/场景 | 必须保持 | 证据 |
|---|---|---|---|
| A1 | UI从未启动/关闭/kill/更新 | 原Pi、子任务、计划/回传继续，新增确认0 | 隔离faux-native事件与owned child结果 |
| A2 | socket慢读/满队列/畸形帧 | handler不await I/O、内存有界、原工具结果不变 | 负载测试与队列/drop/时延记录 |
| A3 | 原生重试/compaction/queued follow-up | 不提前宣告全部结束，不增加模型回合 | 固定生命周期轨迹对比 |
| A4 | UI请求回复丢失/重连/重复点击 | 不重复派发潜在副作用，不错发新epoch | owner invocation计数与操作引用 |
| A5 | 停一个run/暂停一个计划 | 未命中会话继续；计划与当前运行语义分开 | 两会话组合负例与终态证据 |
| A6 | 新旧owner/能力缺失 | 只限制对应UI动作，不降低原native能力 | capability矩阵与原工具仍可调用断言 |
| A7 | 子任务跨前台/后台/多进程 | 原生回传正常，身份不串线 | Subagents固定合同及隔离合成运行 |
| A8 | usage重复/继承/缺失/不同scope | 不双算、不填0、不把窗口当全历史 | 黄金usage fixture与owner结果对照 |
| A9 | 问题关闭/提醒静音/通知失败 | 不代答、不取消原问题、不重跑任务 | producer start/end与执行计数 |
| A10 | 合成secret/raw字段注入 | 不进入wire观察、日志、截图或外发 | canary白名单与输出扫描 |
| A11 | 观察端自身异常 | 不变prompt/tools/model/effort/原策略 | 配置与执行轨迹精确对照 |

性能预算见[架构](architecture.md)；目标值是待测候选，不标成通过。测试覆盖失败/unknown而非只展示happy path。

## 5. 交付与停止

- 本轮停止于可审阅的本地规划，不把空仓首个main创建当普通同步动作，不远端直推。
- 后续本地开发、共享源码、安装、真实接入和发布分开说明。授权覆盖的动作连续完成，不逐任务追加批准。
- 先补会改变设计的最小证据：管理上下文安全、usage归属和背压负例。事实不支持时改接线，不用削弱原自动化、增加LLM判断或取消必要管理来过验收。
- 尚未确定的发行版本号、自动更新渠道和商业分发不是架构前置；实现时按真实范围决定，不预建账户系统、服务端或证书流程。
