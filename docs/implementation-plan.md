---
doc_type: plan
project: workspace
owner_repository: chenhaoxiang/pi-desk
product_line: pi-desk
release_scope: 首版本地源码与旁路候选；非完整发行验收
status: active
truth_mode: maintained
created: 2026-10-24
verified: 2026-10-24
verification_scope: 本地Swift/Node、隔离真实SDK/owner/GUI与已授权本机安装验真；未发布，不含完整真实TUI/Herdr验收
---

# 分阶段实施方案

## 1. 当前交付与下一次实施起点

架构基线为 `e561305`，在原专属树有序接管后连续实施。当前已建立原生App、TS薄扩展、真实owner管理和隔离验证，具体证据见第6节；这不是完整v0.1/业务会话/上线声明。当前新增本机安装授权，按用户Applications固定App与只读bridge版本实施，不以远端空仓或可选现场验收不足新增装机门槛。远端仍空，不能据此直推或bootstrap main；源码、安装和发行分开。

实施与剩余验收沿[本Change任务](../openspec/changes/pi-desk-v0-1/tasks.md)推进。阶段任务是依赖与验收划分，不是逐项人工审批流程；用户后续授权的实际范围决定可连续实施到哪一步。新增运行/生产/账号/预算边界按真实授权判断，不靠文档猜测。

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

- 本次交付为本地源码/旁路候选与真实未完成项；不把空仓首个main创建当普通同步动作，不远端直推。
- 后续本地开发、共享源码、安装、真实接入和发布分开说明。授权覆盖的动作连续完成，不逐任务追加批准。
- 先补会改变设计的最小证据：管理上下文安全、usage归属和背压负例。事实不支持时改接线，不用削弱原自动化、增加LLM判断或取消必要管理来过验收。
- 尚未确定的发行版本号、自动更新渠道和商业分发不是架构前置；实现时按真实范围决定，不预建账户系统、服务端或证书流程。

## 6. 本地实施与证据层级

### 已实现的候选

- SPM App/Core/Transport/有限 peer UID 助手和无运行依赖的 TS bridge；双端共享 wire fixture，主版本、代际、seq、闭集动作、有界队列与同 UID 检查。
- 原生顶栏、六页管理窗口、准确会话身份、分开的连接/回合/输入/owner覆盖、模型/思考档和按需本机元数据。只显示主动接入；Git 元数据仅后台固定只读命令，不逐工具运行。
- native follow-up/steer/abort-current；Subagents ping/status/cost/steer/stop/resume 与公开 schedule allowlist。Workflow 根、后台 child runId、display-only Fleet 对象分开，不用展示 key 控制运行。
- attachment-window 按模型分组、final receipt 去重、未知/partial；owner累计保留原scope和child覆盖，不拼全账户/历史总账。Schema中 owner 未提供的累计起点为 null。
- Schedule Prompt owner 薄 seam 本地提交 `249a8fa8529c4ac988f1b5a4845426ce6aa2dd79`（含首个seam提交 `85c58cd`）（分支 `feat/pi-desk-management-20261024`，未推送/安装）：只复用原 owner 的当前会话列表、暂停/恢复/删除及既有 event-job 触发；不新增 scheduler/CRUD/service。
- 实际 ui_prompt 和可选 question producer 生命周期、已读/静音、系统已授权通知的旁路发送、未接管原兜底；可选安全 evidence reader 和精确本机管理页设置，不消费原始日志或凭据。

### 可复跑的验证

| 入口 | 已证明 | 不代表 |
|---|---|---|
| `npm run check` | 类型、共享协议/usage黄金、过载/去重/旧对象、字段白名单、可选提示/evidence、持久usage writer、公开源码检查 | 真实账号/计费/全模式验收 |
| `bash scripts/check-native.sh` | 本机Swift构建、Core reducer/导航/链接、原生 framing、持久usage ledger日期/去重/坏库/overflow；可执行测试不依赖 XCTest | VoiceOver/系统通知/Herdr实机 |
| `npm run test:native-sdk` | 实际SDK基线/桥接轨迹与loadout一致；新增模型调用/人工确认0；双会话、忙时follow-up/steer、abort终态、实际原生UI输入生命周期 | 业务模型执行或授权所有旧TUI会话升级 |
| `scripts/check-socket-host.mjs` | 实际Swift UDS↔Node两原生会话，双端peer UID、重复请求只执行一次，SIGKILL接收器后Pi继续，重连不重放 | GUI所有显示器/系统行为组合 |
| `scripts/check-subagents-native.mjs` | 固定0.80 owner：真实native child与前台Fleet、精准后台child steer、stop受理/终态、paused恢复成功、stopped恢复拒绝、现有计划暂停与cost | 所有历史owner/runner/远程模式 |
| `scripts/check-schedule-native.mjs` | 固定Schedule候选经真实SDK暂停/恢复、事件触发一次、外会话拒绝；查询新增模型调用0、显式faux触发1 | 已安装/启用常驻监督 |
| `scripts/check-usage-native.mjs` | 实际Pi SDK两个隔离会话的final usage异步记录；App/UDS接收器缺席时仍写盘，App关闭期间续行，loadout不变、真实provider0 | 真实历史账单/未接入旧会话/所有owner附加usage |
| 原生GUI/CUA | 双会话主动接入、原生AX控件、后台发送只命中选定会话，界面requested；总用量页今日/近7天/本月合成预览、搜索与状态过滤、64卡片缩放均读回；截图只在ignored tmp | 完整TUI/系统通知/Herdr现场交付 |

实际对照使用 Pi `1.4.0-fork.1`、Subagents `0.80.0-fork.1` 和上述 Schedule 源码提交；默认开发依赖 Pi `1.4.0` 的 SDK 基线也跑过。真实 provider/账号/密钥调用均为0，未改全局Pi设置、模型/思考档/原工具或业务会话。原生helper和 App 为本仓代码，没有复用 CodeIsland 文件或素材。

首轮独立只读审计绑定 `f4d7481` / `85c58cd`，结论为 OK with notes，不是首版实机验收。后续同面修复保留了明确未入副作用阶段与结果不明的区别：执行后失败只标unknown并保留owner引用、不盲重发；本地未提交的管理草稿不清空；显示按完整UTF-8码点截断；未知子覆盖为null而非0/1。当前有42个Node用例、owner221个用例及直接编译生产AppModel的草稿拒绝/准确目标负例；usage handler 10,000次合成入队p95/p99分别约0.004/0.008ms，队列满只显示下界不阻塞Pi。旧中断socket日志不当成功原件使用，当前成功原件在ignored tmp按实际head重新绑定，CI native job也接入真实socket检查。

性能证据限于合成标量：10,000次观察handler的p95/p99均低于0.01ms（候选机实测），慢socket/10万次离线投影保持有界；同一简单SDK任务的开启/关闭轨迹一致，另有1,000次真实SDK事件dispatch对照（包含宿主派发，实测p95/p99仍满足1ms/5ms预算，不与纯handler数值混标）。一次任务耗时不是通用性能结论，不宣称零开销。CI仅有配置、没有远端运行记录；本机无XCTest，改用同样可失败的Foundation检查runner，未安装Xcode或降低行为断言。

### 本机稳定安装增量

用户随后明确授权本机安装、正常启动与安全验证。`scripts/install-local.mjs` 的 install/verify/rollback 只管理固定用户域App、以source commit命名的bridge和独立自动发现入口；不修改原Pi settings，不升级可选Schedule或启动服务，不强reload旧业务会话。新的 `check-installed-native.mjs` 先用公共resolver确认真实入口可发现，再把同一入口字节放入隔离agent profile，以原生SDK常规自动发现而非 `--extension`/注入registerBridge启用；检查默认helper/socket与实际加载source。具体安装路径、hash、当前进程和本机一次性原件只保存在本机manifest与ignored tmp，不进入公开Git。

### 持久时间总用量与原生可操作性增量

用户将Token主页面改为跨所有已记录会话的Pi总用量。桥接只在`turn_end`取得assistant final的稳定entry ID、UTC occurrence、model和input/output/cache四个白名单标量，使用有界异步writer落到用户域0700目录；不将reasoning/cacheWrite1h子集再相加，不记父owner生命周期累计或归属不明tool usage。App后台通过SQLite `usage_entries`唯一键索引spool，WAL/忙时等待、重开恢复、冲突表、坏库保留、提交后删spool；数据库只存不含prompt/output/path/凭据的元数据。旧桥接只在总览页显示未纳入持久采集，不强reload。

日期总览按本地Gregorian日历和当前IANA时区计算今日、含今日近7天、本月、自定义含结束日范围，内部查询使用`[start,end)`；DST用日历加法，未来桶和未采集桶留空/文字标记，不用0伪装。合成检查覆盖同日双会话、跨日/时区/DST、重复/conflict、缺字段、owner/tool边界、App缺席续行、坏库/符号链接/overflow/队列满。原生总览已读回四桶、趋势、模型分布、搜索和状态筛选；图表与表格数据均有可读label。

视觉优化仍不声称完整现场资格：系统通知只有用户显式点击才申请许可；真实Herdr/VoiceOver和长期业务TUI继续待现场。

### 原生视觉交互增量

用户要求参考CodeIsland顶部区域，重点转为给人看、给人操作的可视化。沿同一Change已实现原生顶部compact/expanded panel、safeArea/无刘海fallback、中文分层卡片、按需消息输入与后置诊断；不改变wire/owner/模型或工具。显式合成预览真实显示了compact、expanded、空态、长名、断连、状态较旧、多会话和浅色管理窗；pin与Escape退出编辑保留草稿已用原生控件验真。核心检查增加中文状态、几何/交互和两个目标切换后的准确epoch管理断言；Reduce Motion路径禁用动效。Escape退出编辑与草稿保留有原生状态回读；Tab有一次精确窗口前台投递失败，最终显式合成窗口投递后原生responder回读为SwiftUI.KeyViewProxy，但没有证明完整焦点顺序。完整键盘遍历与系统辅助技术资格留在2.4/6.3，不冒称全验。预览不连接真实会话、不发送管理动作、不改系统设置。

总用量候选 `cb139bd70ff9b44e9133501ac3f21225c883f255` 已构建为本机 `0.1.0` build `12` 并完成安装/verify、签名与运行验真；App SHA256=`2ec6e9bae1806caed122d1b65e3fedff44e1038cd0d90581b6cccd535b0a3a80`，bridge digest=`4036a6287d28e05dbfc8ed05eeecab802a21087f69554404c3552b0be4c064a8`；上一版 `83926f3d24f7acdae7fca1ad10ccf8e71ec287a3` build `11` 的准确回退保留。新版稳定App真实读回：默认“在线”不把断连卡挤入主列表；真实搜索无匹配时可见计数归零且详情进入选择空态；Token页默认交互口径、缓存/全部可切换，采集覆盖从实际最早记录起，明确本地时区和原始UTC。真实metadata-only聚合和UI对应数值只保存在本机ignored tmp，不将用户具体用量放入公开Git。前述隔离faux-native持久重开3116及旧build5 A追加证据继续有效，动作边界未改。最终compact/expanded/管理窗截图均来自同一视觉源码的显式合成预览，不含业务会话。桥接字节未改，复用原owner/断联/回退证据，不强reload业务Pi；文档状态收口不改已安装候选的source标记。

### A1–A11 / 6.1–6.2 逐项覆盖与缺口

本轮复用既有原件，并把总用量/兼容新增证据绑定如下：

| 矩阵 | 当前证据 | 仍未证明 |
|---|---|---|
| A1 UI关闭/kill/update | 既有UDS kill/无App usage与实际App退出续行；新增10min实际InteractiveMode/PTY soak，receiver重启5次、离线15轮仍落usage | 业务TUI长期运行与更新热加载 |
| A2 慢读/满队列/畸形帧 | native framing、slow socket/overload、usage writer bounded queue/ENOSPC/坏记录；handler p95/p99原件 | 生产规模长期内存曲线 |
| A3 retry/compaction/queued continuation | 既有lifecycle/usage golden、未知边界；新增PTY soak 58轮含12次工具续行，116次settled，usage只收final | 长时间连续retry/compaction业务TUI |
| A4 丢回复/重连/重复点击 | UDS重连不重放、action dedup、usage stable ID与冲突表；旧/新wire混用仍只局部降级 | 真实网络/跨用户环境（本产品不支持） |
| A5 stop/计划与未命中对象 | `check-native-controls`、Subagents/Schedule owner原件；受限owner fixture只隐藏对应控制，Pi message/abort和另一会话仍可用 | 未配置远程owner |
| A6 新旧owner/capability | 旧wire无`usageRecorder`、old owner/缺cap fixture；unsupported run control拒绝但native action继续，UI显示partial/unavailable | 所有历史owner版本组合 |
| A7 父子/前后台 | 既有Subagents child/parent归属及usage boundary golden；工具/父累计不进时间账 | 未加载ambient扩展的真实前台child |
| A8 usage重复/缺失/时间 | usage golden与UsageLedger Swift：DST 23/25h、时区重算、半开、自定义/未来、重复冲突/缺字段/坏库/并发索引 | provider账单或启用前历史 |
| A9 input/通知 | input native check；fake notification authorized/denied/error/delivery-error + 实际稳定App显示未授权；仅用户点击才申请 | 用户系统consent后的真实投递 |
| A10 raw/canary | public source/白名单/原有canary与usage scalar-only；无prompt/output/path/凭据 | 无 |
| A11 observer failure/loadout | baseline/native SDK loadout不变、0新模型/确认；spool/SQLite失败仅partial不改Pi | 长时资源耗尽下全平台行为 |
| 6.1 | A1–A11逐行如上，10min PTY实际InteractiveMode+faux 58轮/140条final、接收器离线重连均过 | 完整业务模式组合及长期真实provider TUI |
| 6.2 | Pi 1.4.0-fork.1、Subagents/Schedule版本原件；旧wire/no recorder/缺cap fixture；不强reload旧Pi | 全历史owner版本与真实混合现场 |

本轮新增 `scripts/check-narrow-ux.sh`：fake notification client验证authorized/denied/request error/delivery error与重复点击；实际稳定App只读回“尚未授权”，未触发系统consent。`scripts/run-pty-check.py --soak` 在独立PTY内运行实际公开InteractiveMode（bridge真实mode=tui）600.005秒：58轮、12次工具续行、116次agent_settled、receiver重启5次/离线15轮，A/B模型调用82/58与持久final记录140严格对应，重连无重放，loadout不变，真实provider/新增确认0，错误0，进程peak RSS约214MiB。非TUI试跑196秒主动终止未当10min证据；结果不替代长期业务TUI/provider资格。

新增通知按钮只在用户显式点击时调用标准系统`requestAuthorization`；启动仅读取状态。custom结束日期早于开始日期时不发新ledger查询，也不替换上一次有效聚合。

### GPT漏采诊断与性能定向修复

真实在线GPT会话的metadata诊断证明仍持有早期无usage spool的bridge；App更新不强reload业务Pi，因此已有GPT会话的接入窗口/owner累计不能按日期补记到新账。当前UI显式显示“旧桥接未纳入”、未采集模型与自然加载提示；没有真实GPT final前不伪造模型账或把unknown填0。隔离fresh GPT-named faux原生链已证明final receipt→异步spool→SQLite distinct model→真实App模型分布，明确synthetic而非真实GPT provider调用。

性能根因是Pi事件总线同步派发OwnerRPC：把`cost`包在setImmediate不隔离owner的branch/artifact I/O。已移除session_start/settled/async完成等自动owner扫描，只有当前用户显式兴趣/刷新才限频合并查询，workflow detail只对所选runId。实际固定Subagents owner的10,128条合成branch/128 children cost RPC同步约0.59–6.06ms，不能声称免费。相同30回合实际InteractiveMode/PTY对照：未接入dispatch p95/p99约0.0051/0.0055ms，接入约0.0238/0.0265ms；turn中位数约1.914/1.894ms，RSS增量约13.2/12.4MB，pending/drop0、新增模型/确认0。仅显式cost刷新触发一次owner读取，不推导零开销或全平台性能。

App ledger现以utility queue持久连接、metadata generation/DB data_version缓存、rowid增量归桶与单一合并刷新代替每轮quick_check/DDL/全范围聚合；定向检查证明10次无变化刷新不增加aggregate扫描，新final只增量读1row；模型过滤与空态仍保留unknown。生产writer实际link后SIGKILL的隔离复现已验证准确自有临时链接恢复；未知第二链接依旧拒绝。真实数据/hash/原件只记本机tmp，不在公开Git暴露真实用量。

### 保留的未完成项

完整v0.1未验收、Change未归档。真实Herdr可执行文件在此机不可用，故精确跳转只有源合同/解析负例，不能假称实机成功；完整VoiceOver、系统通知许可/交付与长时间真实TUI/多显示器组合仍待验证。新question producer缺失时generic custom不猜测来源；真实Gate/CI/服务后台未配置，不读取raw记录凑数。本地release App为arm64，codesign ad-hoc验证通过；实际GUI杀App后两原生faux会话继续执行（原A/B 2/1次变3/2次），App重启重新登记且调用数不变，没有重放。已授权本机安装不等于发行签名、公证、自动更新或对外上线。公开远端空main仍未初始化，独立审计/PR/CI/合并分别保留真实状态。
