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
| `npm run check` | 类型、共享协议/usage黄金、过载/去重/旧对象、字段白名单、可选提示/evidence、公开源码检查 | 真实账号/计费/全模式验收 |
| `bash scripts/check-native.sh` | 本机Swift构建、Core reducer/导航/链接、原生 framing；可执行测试不依赖 XCTest | VoiceOver/系统通知/Herdr实机 |
| `npm run test:native-sdk` | 实际SDK基线/桥接轨迹与loadout一致；新增模型调用/人工确认0；双会话、忙时follow-up/steer、abort终态、实际原生UI输入生命周期 | 业务模型执行或授权所有旧TUI会话升级 |
| `scripts/check-socket-host.mjs` | 实际Swift UDS↔Node两原生会话，双端peer UID、重复请求只执行一次，SIGKILL接收器后Pi继续，重连不重放 | GUI所有显示器/系统行为组合 |
| `scripts/check-subagents-native.mjs` | 固定0.80 owner：真实native child与前台Fleet、精准后台child steer、stop受理/终态、paused恢复成功、stopped恢复拒绝、现有计划暂停与cost | 所有历史owner/runner/远程模式 |
| `scripts/check-schedule-native.mjs` | 固定Schedule候选经真实SDK暂停/恢复、事件触发一次、外会话拒绝；查询新增模型调用0、显式faux触发1 | 已安装/启用常驻监督 |
| 原生GUI/CUA | 双会话主动接入、原生AX控件、后台发送只命中选定会话，界面requested；截图只在ignored tmp | 完整TUI/系统通知/Herdr现场交付 |

实际对照使用 Pi `1.4.0-fork.1`、Subagents `0.80.0-fork.1` 和上述 Schedule 源码提交；默认开发依赖 Pi `1.4.0` 的 SDK 基线也跑过。真实 provider/账号/密钥调用均为0，未改全局Pi设置、模型/思考档/原工具或业务会话。原生helper和 App 为本仓代码，没有复用 CodeIsland 文件或素材。

首轮独立只读审计绑定 `f4d7481` / `85c58cd`，结论为 OK with notes，不是首版实机验收。后续同面修复保留了明确未入副作用阶段与结果不明的区别：执行后失败只标unknown并保留owner引用、不盲重发；本地未提交的管理草稿不清空；显示按完整UTF-8码点截断；未知子覆盖为null而非0/1。当前有33个Node用例、owner221个用例及直接编译生产AppModel的草稿拒绝/准确目标负例。旧中断socket日志不当成功原件使用，当前成功原件在ignored tmp按实际head重新绑定，CI native job也接入真实socket检查。

性能证据限于合成标量：10,000次观察handler的p95/p99均低于0.01ms（候选机实测），慢socket/10万次离线投影保持有界；同一简单SDK任务的开启/关闭轨迹一致，另有1,000次真实SDK事件dispatch对照（包含宿主派发，实测p95/p99仍满足1ms/5ms预算，不与纯handler数值混标）。一次任务耗时不是通用性能结论，不宣称零开销。CI仅有配置、没有远端运行记录；本机无XCTest，改用同样可失败的Foundation检查runner，未安装Xcode或降低行为断言。

### 本机稳定安装增量

用户随后明确授权本机安装、正常启动与安全验证。`scripts/install-local.mjs` 的 install/verify/rollback 只管理固定用户域App、以source commit命名的bridge和独立自动发现入口；不修改原Pi settings，不升级可选Schedule或启动服务，不强reload旧业务会话。新的 `check-installed-native.mjs` 先用公共resolver确认真实入口可发现，再把同一入口字节放入隔离agent profile，以原生SDK常规自动发现而非 `--extension`/注入registerBridge启用；检查默认helper/socket与实际加载source。具体安装路径、hash、当前进程和本机一次性原件只保存在本机manifest与ignored tmp，不进入公开Git。

### 原生视觉交互增量

用户要求参考CodeIsland顶部区域，重点转为给人看、给人操作的可视化。沿同一Change已实现原生顶部compact/expanded panel、safeArea/无刘海fallback、中文分层卡片、按需消息输入与后置诊断；不改变wire/owner/模型或工具。显式合成预览真实显示了compact、expanded、空态、长名、断连、状态较旧、多会话和浅色管理窗；pin与Escape退出编辑保留草稿已用原生控件验真。核心检查增加中文状态、几何/交互和两个目标切换后的准确epoch管理断言；Reduce Motion路径禁用动效。Escape退出编辑与草稿保留有原生状态回读；Tab有一次精确窗口前台投递失败，最终显式合成窗口投递后原生responder回读为SwiftUI.KeyViewProxy，但没有证明完整焦点顺序。完整键盘遍历与系统辅助技术资格留在2.4/6.3，不冒称全验。预览不连接真实会话、不发送管理动作、不改系统设置。

已验证视觉源码 `4f8846f69aab02e7ebc93f0dc89a5cdb7883341f` 构建为本机 `0.1.0` build `5`，稳定App/固定bridge的安装、签名、字节清单与实际运行source均回读一致；上一版 `027572e36fc9143f1c8ade44156ded44d417c5f2` build `4` 的准确回退保留。新管理窗通过真实安装入口自动发现的两个隔离faux-native会话验证：在A卡片追加要求后，A调用数1→2、B保持1，真实provider调用0。最终compact/expanded/管理窗截图均来自同一视觉源码的显式合成预览，不含业务会话。桥接字节未改，复用原owner/断联/回退证据，不强reload业务Pi；文档状态收口不改已安装候选的source标记。

### 保留的未完成项

完整v0.1未验收、Change未归档。真实Herdr可执行文件在此机不可用，故精确跳转只有源合同/解析负例，不能假称实机成功；完整VoiceOver、系统通知许可/交付与长时间真实TUI/多显示器组合仍待验证。新question producer缺失时generic custom不猜测来源；真实Gate/CI/服务后台未配置，不读取raw记录凑数。本地release App为arm64，codesign ad-hoc验证通过；实际GUI杀App后两原生faux会话继续执行（原A/B 2/1次变3/2次），App重启重新登记且调用数不变，没有重放。已授权本机安装不等于发行签名、公证、自动更新或对外上线。公开远端空main仍未初始化，独立审计/PR/CI/合并分别保留真实状态。
