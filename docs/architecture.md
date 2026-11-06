---
doc_type: plan
project: workspace
owner_repository: chenhaoxiang/pi-desk
product_line: pi-desk
release_scope: 本机实现与首版已配置路径收口；非正式发行或全宿主认证
status: active
truth_mode: maintained
created: 2026-10-24
verified: 2026-11-06
verification_scope: 本轮mission决策消费Swift/TS负例和实际管理SDK/Swift UDS；复用已交付W1/W2，不含新GUI/FPS或完整自然自治资格
---

# 系统架构

产品边界见[产品范围](product-v0.1.md)，具体接口及版本见[矩阵](integration-matrix.md)，行为要求统一在[现行规格](../openspec/specs/)，初始设计保留在[首版归档](../openspec/changes/archive/2026-10-30-pi-desk-v0-1/proposal.md)。本页是实现结构与取舍，不是新增治理权威。

## 1. 进程拓扑

```text
现有 Pi A ─ desk-bridge 扩展 ─┐
现有 Pi B ─ desk-bridge 扩展 ─┼─ 本机 Unix socket ─ Pi Desk 原生 App
现有自有 RPC 宿主 ─ 同一扩展 ─┘                    ├─ 顶栏/可选刘海面板
  │ 各自原生API/事件总线                           ├─ 管理窗口
  ├─ Subagents / Intercom / Schedule               └─ 内存显示投影
  └─ 原工具、权限、Guard/Gate照常运行

现有管理系统 ← 用户已配置的受限API或精确页面链接 ← App（可选）
```

只有一个新的 App 和一个运行在原 Pi 内的薄扩展；不引入 daemon、常驻总控或新 RPC Pi 子进程。App接收器可以随App退出，Pi不依赖它；扩展离线时仅保留有界最新状态并退避重连，不启动模型、终止会话或写任务账本。原生RPC的读取者仍是原宿主，不让App承担其stdout持续消费责任。

## 2. 技术与模块选择

- **macOS 14+，SwiftUI + AppKit**：SwiftUI管理窗口/列表，AppKit顶栏/浮层/窗口焦点；SPM管理，先arm64验证，再依据发行需求补Intel构建。菜单栏入口始终可用，无刘海/外接屏不损功能。
- **TypeScript薄扩展，Node标准库**：宿主SDK作为type/peer，不打包另一套Pi；起点对照Pi 1.4.0-fork.1，兼容资格按隔离测试而非版本字符串猜测。
- **UDS + 有界LF-JSON协议**：无HTTP端口、WebSocket服务和跨网发现；本机usage专用SQLite索引只存白名单元数据，不是业务任务数据库。Native socket读取在后台串行队列，UI只接收合并后的不可变快照。
- 不引入通用plugin框架、事件代理平台或OTel Collector。增加一个具体owner适配器不代表支持所有工具。

已建目录（实现为本地候选，非安装声明）：

```text
Sources/PiDeskApp/           # SwiftUI窗口、顶栏及导航
Sources/PiDeskCore/          # 身份、状态reducer、统计scope、操作状态
Sources/PiDeskTransport/     # UDS、LF framing、限流和peer检查
packages/desk-bridge/src/    # Pi生命周期、owner adapters、非阻塞投影
Tests/                      # Swift纯逻辑/协议/本机隔离集成
packages/desk-bridge/test/   # Node/真实SDK faux-provider测试
docs/                       # 本页、产品、交互、接口与实施说明
openspec/specs/              # 现行行为合同
openspec/changes/archive/2026-10-30-pi-desk-v0-1/  # 首版实施历史
```

`Sources/PiDeskPeerCheck/` 是有限 syscall 助手，不是第三个运行宿主：在桥接的异步连接验证阶段经公开 stdio 传递 fd，仅执行 `getpeereid` 并退出。它随 App 打包，缺失/失败只使该观察连接不可用，绝不替换为不验证 peer 的连接。

不提前建立第三个协议SDK包；跨语言共享wire fixtures和封闭schema，编译实现只放两端必要结构。

## 3. 状态与身份

### 3.1 身份

主键是 `{localHostId, nativeSessionId, runtimeEpoch}`，epoch每次扩展runtime替换生成。会话名/cwd/PID/tty只作显示或经过验证的跳转信息，不作控制身份。

子运行使用owner `runId`与必要child index。Fleet display key只用于展示，不能转换成控制ID。Pi进程内多个会话不能用process-global parent变量当完整父子树；先用Subagents owner投影，环境字段最多是待核实提示。

App断线重连同一epoch，要求全量当前快照并保留monotonic seq；新epoch清除旧控制能力和未完成UI请求绑定。对旧epoch晚到的回复/动作拒绝，不把旧模型、状态或对象当当前。

### 3.1.1 体验投影与本机偏好

可选 `activity` 只由真实 agent_start、工具开始/结束、agent_settled 与准确子任务事件更新，包含有界 sequence/kind/at、回合起止及结束序号。心跳、刷新、startup idle 对账不更新该时钟；不转发消息、工具参数或结果。旧 bridge 缺字段显示活动时间未提供，不强制 reload。未查看变化要求当前执行证明、无 pending 且状态为已结束/异常/中止，并按 runtime 的结束序号记已查看，不能代替业务验收或回答输入。

主列表只在用户主动置顶时改变分组，普通状态变化不重排；顶部速览在展开时按输入、异常、未查看变化、置顶、运行选择至多四个在线对象，并冻结该次展开的准确 identities 和槽位；失效 epoch 以等高禁用占位保留，不让后续行或编辑器前移。原会话路由及操作反馈也绑定 identity/epoch，异步回执不跟随当前选中对象漂移。

显示别名由用户主动输入，最多32个、每个128字节；置顶和结束已查看各最多64项。它们复用私有 `app_view_state`，会话键只保存 hash，别名不包含自动采集的原始名称/路径。v1新增字段为optional、旧偏好兼容；单行上限128 KiB覆盖既有1024个输入已读标记及新增偏好的共同上限，不创建新库、扫描或权限。Pi原生设置仍只有原生文件白名单和独立的安全写入路径。

### 3.2 分开保存的维度

| 维度 | 示例 | 不可推导 |
|---|---|---|
| connection | connected / stale / disconnected | 断联不代表任务失败或已停止 |
| execution | starting / running / retrying / compacting / waiting-children / settled / failed / aborted / unknown | settled不代表业务目标或所有外部工作完成 |
| attention | none / input-required / result-unread / warning | 未读不触发继续，不把idle视为需人 |
| management | ready / unsupported / unavailable + request状态 | 按钮可用不是授权或成功 |
| verification | not-checked / pending / verified / stale / failed / unknown | 显示的成功不生成merge/部署许可 |

`agent_end`不是完成边界；执行状态由`agent_settled`和公开`ctx.isIdle()`/`hasPendingMessages()`标量对账，启动后一次deferred reconcile消除startup暂时busy。observe及现有5秒heartbeat只重采这两个内存标量，不加owner RPC、模型或同步I/O。可选`executionObservation={version:1,observedAt,source,idle}`与连接`observedAt`分离：ctx不可用不刷新执行证明；失败/中止的已观测结果在idle时保留，native重新busy则回到运行。真实input优先，native idle清除遗留工具名；pending消息不冒称AI已开始执行。

异步start/complete与process-terminal事件只按当前session/exact runId（必要child index）更新有界child cache；terminal proof清除running但不伪造业务成功，无法精确归属的Fleet cache置unknown。缺子任务覆盖不宣称全部工作结束。App的连接badge、执行badge独立，计数/运行中筛选/默认重点共用同一执行判断；仅统计已主动接入，旧wire缺执行proof时active标待核并给待核数量，不用source SHA差异决定busy/idle。旧terminal结果保留为“上次”观测，不能以新heartbeat当本轮事实。普通工具出错不自动把会话变成失败。

## 4. 连接、观察与背压

### 4.1 接入与发现

只显示主动注册的Pi。扩展启动于`session_start`，清理于`session_shutdown`；不在factory建立连接，不扫描进程/历史目录，不安装或修复其他扩展。已运行会话仅在安全自然加载/原有reload后接入，不强制重启。

原生App在私有运行目录创建socket；扩展只连接该固定用户域socket。App重启后各会话以有界退避+抖动重新登记。心跳是轻量连接可用性，不代表Agent忙闲，不唤醒模型。显示陈旧阈值按连接超时判定，不把无工具输出当无响应。

### 4.2 非阻塞生产

观察使用notification型事件，拿必要标量后同步入队并立即返回undefined。禁止在`tool_call`、`tool_result`、`context`或`agent_before_settle`建立阻塞审批/变换/continuation；不订阅原始provider stream或逐token转发。

建议初始传输预算（实现前用负例校准，非已验证性能）：每连接最多128待发记录或1MiB、单帧最多64KiB、display文本最多512字节；管理文本最多16KiB。状态与usage快照按键合并，慢端按最新值替换。过载丢显示事件后累计drop计数并要求当前快照，不能重跑业务来补事件。

socket写、序列化、可选branch查询和owner统计放到有界后台调度，不在原事件handler await。扩展不逐工具同步跑ps/git，不逐事件读取会话或owner artifacts。长统计切片让出事件循环；不承诺Promise timeout能隔离同步CPU。无同等真实用例性能证据不得称零影响。

### 4.3 本机安全边界

运行目录0700、socket仅本用户访问、拒绝符号链接/错误owner/意外文件，客户端和服务端均验证peer UID及连接代际。只保证合作本机用户域，不宣称隔离同UID恶意代码。Unix path长度与启动冲突进入定向失败测试。

配置的Herdr地址与管理URL仅存在受限本机设置，不硬编码到公开源码。跳转只允许固定Herdr动作/终端适配，不执行hook payload提供的任意二进制或shell。管理页链接校验scheme和明确配置目标，不接收事件中的任意URL。

## 5. 最小wire合同

这是一条非权威本机传输，不是执行/授权证明。首版只支持主版本1，未知字段忽略、未知action拒绝；主版本不匹配仅停该连接的管理，不影响Pi。

| Record | 方向 | 必要内容 |
|---|---|---|
| hello | 扩展→App | protocolVersion、身份/epoch、source labels、capabilities、统计scope |
| snapshot / update | 扩展→App | 身份、seq、observedAt、revision、白名单状态/usage/owner摘要 |
| query | App→扩展 | requestId、准确身份、命名只读query，最多一个同类in-flight |
| action | App→扩展 | requestId、准确身份、owner target、固定action enum、有限参数 |
| action-result | 扩展→App | requestId、rejected/accepted/queued/requested/unknown，owner handle/原因 |
| operation-update | 扩展→App | 同一owner引用的实际执行/终态，不能由socket送达推导 |

断线后的App不重放action。一次点击只生成一个请求；重复同ID在同epoch的有效缓存内只返回相同受理结果，不能再次执行；同ID不同参数必须拒绝。已知缓存过期/新epoch/潜在副作用不明时返回unknown并按owner引用对账；不承诺在记忆窗口外识别任意重复提交，不承诺持久exactly-once，不建立新操作账本。owner回报已进入执行但失败、超时或无分类错误时保持unknown并保留已知owner引用；只有原owner明确证明尚未入副作用阶段才显示rejected。Schedule seam分别使用request-rejected与operation-outcome-unknown，不把旧management-unavailable视作未执行证明。

控制请求数量与回复队列独立限流，不用普通状态覆盖回复。当前生产端采用1条合并快照＋32条回复，App每连接/每批也有上限；组合DTO按字节预算投影并保留omitted/partial，不让合法大快照超过64KiB后永久断联。

App请求由连接owner在原宿主事件循环的应用层回调处理，不从新模型工具或tool_call内递归调用工具。确需模型执行的新要求明确进入原生sendUserMessage队列；普通查看/管理不以LLM代替确定性API。

## 6. 管理与现有接口

- `session.message`：原生`pi.sendUserMessage`，明确steer/followUp，不通过terminal send-key；不把任意slash文本当通用管理端点。该API返回void，因此bridge只能报告`requested`（已调用提交路径）；只有具有关联的owner收据才可标accepted/queued，缺少该证据不能从调用返回猜测已入队，实际处理另观测。
- `session.abort-current`：当前ctx.abort，请求后观察终态。明确它不是暂停schedule、清空queue或停止所有子任务；只中止当前回合，可能仍有后续原生工作。
- `run.steer/stop/resume`：复用Subagents进程内RPC并查询capabilities。Workflow 根只用于根级动作；后台孩子从公开定向 `status.details.workflowChildren` 取得真实 runId，不用 workflow key/Fleet key。resume在原owner验证租约/状态，失败不新建替代运行。
- `schedule.*`：保留owner命名空间。Subagents只用其managementActions allowlist；Schedule Prompt 管理 seam 已在该 owner 的独立本地候选补齐并隔离验证，未全局安装。旧 owner 缺 seam 时只显示不可用，不直接读写其 JSON。
- Intercom v1 outbox没有wake/mode，不能据此承诺精确唤醒/纠偏；自己的已接入会话优先走直接原生接口。跨peer操作只在owner接线明确后开放。
- 原问题回答继续在原TUI；首版准确通知与跳转，不拦截ask工具或要求先在App回答。已有自动决策/审批路径不变。
- 治理/Gate/CI和SAW都是可选集成。实际记录有来源/head/freshness才展示相应事实；缺少reader不读私有审计全文。首版SAW以打开选定现有页面为主，不新增凭据库或操作权限。

未实现能力只禁用相应按钮并说明原因，不把整个会话改成待人。App与原AI/CLI接口是并列入口，不替换后者。

## 7. Token 统计

详见产品范围，关键设计如下：

1. 普通扩展没有ctx.getSessionStats。以`attachment-window`为诚实默认：只累计接入后的final usage，流式累计值不逐帧相加。标明windowId、startedAt、coverage。
2. 以稳定entry/owner receipt identity去重；没有稳定ID时不猜测重放是否新消费，标partial。扩展重载新窗口不拼成全历史总数。
3. 现有native宿主可给`native-session-total`时保留原语义；TUI不为取数改成裸SDK/RPC，不导入内部AgentSession。
4. Subagents `cost`由原owner读取当前分支和关联产物，底层RPC可能同步占Pi事件循环；因此只有用户显式查看/刷新准确会话的usage时才有界调用，settled/async完成、App缺席或收起不自动扫owner cost。普通状态查询也按用户当前对象合并/限频，workflow detail仅定向所选runId。它可提供parent/children/childTotal/total和unresolvedAsyncChildren，直接保留来源与下界，不在App重算一份相冲突的总账。
5. `usage`、compaction、branch summary及nested tool usage必须与宿主归一规则对照。首阶段先建立合成合同，未覆盖的附加消耗明确标partial，不把只看assistant消息称完整账单。
6. same child既作为独立Pi注册又在父报告出现，显示可以两处关联，汇总只取一个owner归属；无可证明不重叠关系则不展示精确全局合计。
7. Context usage是上下文占用，不是花费；缺失/未结算值为null。无权威价格/费用结果不推算金额。
8. 时间总览新增最小本机持久元数据链：bridge在final handler只投递标量到有界队列，异步写0700/0600原子spool；App后台导入SQLite，以不含epoch的稳定receipt hash唯一去重。App离线仍写入；不新增Agent/daemon、同步handler I/O或常驻历史扫描。writer关闭后允许最后刷盘，永久故障最多三次关闭态失败尝试后释放timer并保留pending/writeFailures；正常关闭继续排空全部有界批次，不把未落盘报成功。
9. 实时链只收Pi assistant final自身usage，不收流式中间值、父owner累计或不可证明不重叠的工具聚合；子会话自己的final可独立计入，未接入孩子/工具/压缩等附加量明确缺口。日期使用原始request UTC时间，绝不把累计到达日当消费日；无时间的记录只标缺口。
10. 按用户本地Gregorian日历及显式IANA时区算今日/近7天/本月/自定义日期；结束日转下一天零点，查询[start,end)。跨DST用Calendar加天，不按24小时推算。自定义最多400天（含首尾日期），UI与ledger共同拒绝超界，主数/趋势/表不使用不同范围；无效输入保留上次有效结果。未来与采集起点之前的桶分别显示尚未发生/尚未采集，缺字段聚合已知量并标下界，不以0伪装未知。
11. SQLite索引仅服务用量查询/去重，事务提交后才清理已导入spool，崩溃重导幂等；utility queue持有连接，schema/quick_check只初始化，metadata dirty代际/DB data_version未变时复用范围结果，新rowid只增量归桶，刷新仅单一在途/最新合并。utility内最多保留3个日期范围的bucket/model/source投影，暖范围/来源/模型不在主线程遍历原库；空spool不启写事务。schema/health check只初始化，诊断计数与定向检查核对重复refresh不增aggregateRows，新final仅增量。预算/失败保留coverage，不把失败扩为Pi门禁。旧bridge不支持持久记录时明确提示未纳入，不将显示快照补记为今天。
12. hard-link publish后进程崩溃留下双链接时，只在本工具私有spool证明最终ID文件和准确`.usage-UUID`临时项同inode/device/owner/mode、结构及SHA256内容相同且nlink恰2后移除临时链接，再沿原严格reader导入；未知第二链接不放行、不删除。

### 一次性历史usage补采（2026-10-26授权）

独立低优先级worker只在显式preview/apply/rollback命令下运行；不挂入App启动/refresh或Pi事件链。preview/apply先对source及允许的canonical/tmp根解析真实路径再作准确包含判断，不允许../或祖先symlink把读取扩到源范围外；rollback不要求历史源仍存在。canonical Pi JSONL以只读fd、冻结dev/inode/size和prefix SHA256读取，单worker分块流式投影，单行16MiB、缓存有界并节流。仅stage标量与哈希，不保留原路径、会话ID、正文、工具参数/结果或模型配置。包含所有已付费分支的assistant/usage/compaction/branch_summary，不只读当前leaf；非Pi sidecar镜像不再计入。

消费键与实时完全一致：host hash → session header ID hash → entry ID hash，不另设history命名空间绕开去重。fork/clone的新header不能让复制消费再次计费：沿parentSession链比较entry ID和usage fingerprint；不把8hex ID当全局ID；缺链、循环和内容冲突保守ambiguous。summary无provider/model保持unknown，缺桶保持null；reasoning/cacheWrite1h不再相加。

apply绑定preview/source-set hash并校验冻结前缀，正常退出本App维护时Pi仍spool；SQLite backup API获得包含WAL的一致快照，原DB/WAL/SHM和install manifest只作补充备份，目录0700/文件0600。单事务插入、quick_check、import receipt；重复apply幂等。八列usage_entries保持兼容，provenance/import/alias/conflict为附加表；来源标签不改变消费identity。rollback只移除该import新增且未实时确认的行，后续实时数据和既有冲突审计不清除；App回退与数据回退分开。

UI从索引展示实时/一次性历史/去重合计，以及各来源最早记录、冻结覆盖日期和不完整原因。utility queue缓存按rowid增量归桶/来源，模型筛选保持同口径；不会为展示重新打开JSONL。

### 同口径时段对比

用户展开对比时，App先接收本期结果，再顺序查询相邻的前一等长日历日范围，避免既有 latest-only 合并队列丢掉其中一个回调；任一筛选变化都重新绑定本期/前期，旧在途结果不覆盖新选择。比较只取两期均已结束的前N个小时/日桶，不包含当前未结束桶；来源、物理模型、metric和时区相同才可计算。未知桶、缺字段、索引故障/待索引/冲突、溢出及按来源结构化的采集器丢弃/待落盘/写失败、历史导入跳过或冲突均抑制百分比；正常的统计范围说明不算采集缺口，前期真实零保留零但不算百分比；DST导致单日小时数不同时明确不可直接比较。结果仅为已记录元数据对比，不是全量消费、额度或账单变化。默认折叠不增加查询，展开仍复用既有utility队列与至多3范围缓存。

### 本App窗口兴趣与统计首屏

manager自身NSWindowDelegate传递可见/occlusion/miniaturize/close及App hide状态，不轮询其他App。Token页真实可见时5秒刷新，其他可见页30秒，遮挡/最小化/关闭但App存活时60秒；页面保留Token不会维持前台频率，重新可见按需更新。Pi final采集仍在原Pi异步继续，关闭UI不停止采集。所有查询留在单utility queue/合并请求路径，不添加owner自动cost/status、daemon或后台模型。Chart只在bucket/range/metric变化时重算，不因更新时间或无变化heartbeat重画。

性能原件使用只读proc_pid_rusage累计CPU时间/物理磁盘IO/RSS，30–60秒按统计可见/其他页/最小化/关窗分开；记录同range/origin/model与期间实际新增行，磁盘页缓存0读不解释为无工作或零开销。真实usage与进程原件只在本机tmp，公开文档不保存用户具体消费。

### 原会话定位、创建时间与Pi设置边界

App的UDS server在accept后读取LOCAL_PEERPID及peer birth；utility queue按connection+identity/epoch一次性核验同uid进程controlling TTY和最多12层Terminal祖先，PID复用/断开/epoch变化作废。fallback只补旧bridge缺route，不扫全进程/正文、不启动第二writer，新bridge route优先。Terminal权限分只读preflight与用户主动请求（OS决定）；preflight与实际AppleEvent都在Pi Desk进程内对相同Terminal PID发出，不再经osascript子进程。固定AE路径在utility串行队列运行，单次总12秒/单event最多2秒、单一在途，最多8个Terminal实例/512 tabs；不读终端内容或提供任意脚本入口。失败保留安全OSStatus与固定阶段，不用“已授权”覆盖真正send错误。

bridge在session_start一次性从公开SessionManager header读取ISO timestamp，投影为有界`display.createdAt`毫秒和`createdAtSource`（`session-header`/`unknown`）；不读历史正文、不把observedAt/首次接入当创建时间，超界或非法时间拒绝。route只在当前主动接入context中捕获：Herdr route保存精确pane/sessionFile；Terminal.app route一次性读取本进程TTY（macOS `/dev/fd`不可靠时用固定`/usr/bin/tty`继承fd，最多500ms），保存严格ttyPath、TERM_SESSION_ID和可选tmux/WezTerm/cmux标量；携带tmux/WezTerm/cmux时不把内层pty冒称Terminal tab，当前保持不可用，待对应客户端精确focus合同另行接入。UI只对唯一精确route聚焦，同进程AE先收集所有已运行Terminal实例的窗口ID/tab TTY，count非1或枚举不完整不解最小化/不激活；以PID+launchDate守护实例，按稳定window ID与tab索引在变更前复核TTY，再只选准确tab/前置准确窗口/激活准确实例，回读front window ID、selected TTY和前台实例后才标成功。Automation拒绝/route缺失显示unknown。绝不按cwd/名称挑第一个窗口，不对活跃会话自动`pi --session`启动第二writer；仅用户后续明确选择且源已确认不活跃时才可另行设计恢复。

Pi设置首批只投影canonical user `<agentDir>/settings.json`的白名单字段：theme、defaultThinkingLevel、steeringMode、followUpMode、compaction.enabled/reserveTokens/keepRecentTokens、retry.enabled/maxRetries/baseDelayMs/maxAgentDelayMs、quietStartup、tuiMode、terminal.showImages/showTerminalProgress。SettingsManager公开schema作为字段依据；项目overlay只读显示来源，不把两层合并回写；auth/models/mcp/packages/resources/proxy/trust/permissions/defaultModel/defaultTools等排除。原文件读取/写入在utility queue，兼容Pi的atomic mkdir `settings.json.lock`（不清理未知锁，短事务）、owner-only revision backup、mtime/hash CAS、atomic temp+rename+fsync和readback；坏JSON、权限、锁、冲突、未知类型只读保全，未创建文件明确显示尚未创建。

## 8. 隐私、展示与诊断

默认白名单只含身份、状态枚举、工具名、计数、模型/effort标签及必要本机显示信息。项目/分支/本地路由属于私有display字段，只留当前用户内存，不写公开fixture、持久日志或外发通知。默认不传prompt、代码、命令参数、tool result、思考、会话正文或凭据。

用户主动输入的管理文本单独走action通道，只交给目标owner，不进入telemetry/历史/推送；终端仍保留原会话行为。源级白名单优先于通用正则，遇到异常数据只记录固定诊断码，不回显原件。日志仅版本、耗时、drop/error计数等安全aggregate；固定保留限额，默认不开原始数据导出。

通知从状态变化触发，不轮询LLM。保留现有通知兜底；只有原producer提供稳定事件ID且接管交付成功才抑制相应重复表现，首版无法证明时宁可保留原通知，不静默关闭它。静音/已读不写执行状态。

## 9. CodeIsland 复用决策

不整库fork、不导入AppState/ConfigInstaller/HookServer/多工具Discovery。对照快照中NotchPanelView约5764行、PanelWindowController约735行，不能假定抽文件即独立可用。优先以系统API重做小型外壳；ScreenDetector/动画/Herdr路由仅在依赖、维护收益和许可检查通过后局部复用。

真实复用时再增加归属与上游MIT许可，不现在预建空第三方体系。纯原创外壳与适配不假称继承上游签名、公证、自动更新或Buddy支持。

时间总览还参考[ccusage日期报告](https://ccusage.com/guide/daily-reports)的跨会话时间视角与四桶口径、[CodexIsland usage-only持久记录说明](https://github.com/ericjypark/codex-island/blob/main/docs/USAGE-HISTORY.md)的稳定ID/SQLite/陈旧值边界，以及[CodexBar](https://github.com/steipete/CodexBar)的原生状态反馈。只借鉴展示和统计边界，未复制代码/素材，不接它们的历史扫描、登录凭据、额度/定价或多provider层。常驻记录仍只来自当前Pi final；本次显式一次性补采是自有metadata-only worker，并未接入这些参考项目的历史/认证组件。

## 10. 可选 AI 辅助旁路

Pi Desk AI不是Agent宿主、执行器、审批人或业务状态owner。它由用户主动进入AI助手后触发目录读取，明确分析后才推理。App优先按需调用本机已安装Pi的公开 `ModelRuntime/ModelRegistry` 与请求时认证：一次性Node子进程复用同一DeskAssistant校验器，只允许models/analyze/cancel，不创建AgentSession、不加载扩展/工具、不写Pi设置或会话。有界stdin传上下文，stdout只回协议payload，stderr不回App；EOF/取消/退出只取消该AI，不杀断SDK认证事务：UI可以及时返回unknown，helper以SDK1.5刷新15秒上限之外的20秒安全窗口等待后自然退出，保留尚未结束的IO/锁释放；无process.exit/SIGKILL，收到终态不terminate，Swift超时/停止仅发正常SIGTERM，由SDK初始化前安装的handler处理。最多4个未退出子进程，安全收尾不无限派生。目录使用无网络初始refresh恢复已保存新增/能力/个性化缓存，目录探测失败只有限降级到在线models，不重发unknown analyze。目录查询无推理。缺少本机SDK时保留准确在线Pi的公开注册表通道；基础观察、输入提醒、健康页、控制和用量采集不等待它、不因它不可用降级。默认模型为 `codex-local-8319/gpt-6.1-sol`、`medium`，配置存本机Pi Desk设置，可改但只影响Desk旁路；cphone/zooapi及非注册/不可用模型拒绝，SDK的pi-virtual别名也在列表和推理准入同时排除，避免别名路由改换实际模型/档位。不静默换渠道、换模型、降档或重发未知请求。

请求走独立 `assistant-request/assistant-response` UDS lane，客户端最多16个在途请求、bridge最多32个有界短期收据、每个客户端一次1个推理、请求有界超时与取消；Assistant回复不进入普通Pi快照，不在工具/生命周期回调里等待，不调用 `session.prompt`，Pi业务会话的model/thinking/tools/历史不变。回复仅有状态、结构化模型/上下文/分析和数值usage，文本上下文与AI正文不写日志/usage库（仅内存短缓存；用户明确采纳的有界分组标签作为私有显示偏好保存）；usage未确认时标unknown/possible，不伪造费用。非空成功结果的四桶全零没有独立结算证据，按SDK缺省值保守记为用量未确认，不推算Token。

上下文必须由用户明确选择1–8个已接入准确runtime。bridge沿当前leaf通过公开 `SessionManager.getLeafId/getEntry` 有界回溯最多128个entry，每个来源取最多8条用户/assistant文本、每条2048字节，整个AI请求最多8个来源/32KiB；不走`getBranch`、不发现历史文件、不读取废弃分支、thinking、toolCall、toolResult或凭据。发送前UI显示消息并允许逐条移除；bridge与App双方做疑似密钥/令牌/密码预检，命中则拒绝发送（这是保守预检，不是完整DLP）。AI上下文来自当前runtime，旧bridge只给元数据/不可用，不强制reload。

模型输出必须是有界结构化的overview、每个输入ref一条summary、可选不重叠分组建议；ref必须来自本次输入，来源主标题取Pi原生/name而非本机别名，桥接在快照及session_info_changed时读取公开名称标量，无owner轮询/文件扫描。来源/时间/runtime通过App绑定，结果过时不得改新runtime标签。内存缓存键包含准确broker和来源identities，命中后保留原来源，不能因文本相同改绑到替换运行；这些identity只用于本机缓存，不额外发给模型。采纳只写本机工作组标签，不发Pi管理请求；失败/取消/超时/未知不自动重试。合成和真实指定模型验真分开，CI默认faux provider，不携带真实凭据。

### UI 热路径与短缓存

流畅度修复保持原始快照/诊断/管理语义：AppModel只对派生会话列表做内存缓存，store变化失效行投影，成员/主动置顶/接入顺序变化才重排；搜索/组/隐藏/别名/已查看等对应偏好独立失效可见或关注投影。名称/执行状态更新仍取新快照、保持已接入行顺序；控制始终重新核准确identity，不把缓存变成控制权威。偏好SHA256键最多缓存2048个，不持久化正文；摘要编码仍为相同小写64位hex，使用字节表代替每字节Foundation格式化，旧数据库/通知键不迁移。

AI页重入对成功模型目录复用60秒内存缓存（broker仍须准确且可用），显式“刷新注册模型”绕过缓存；不缓存未知分析或新增推理。合成64行相同checksum的页面模型投影基准仅报告计算耗时，不冒充真实滚动帧率；定向回归检查warm读取不重复排序、偏好与同key快照均正确失效。

## 11. Pi同源任务观测与CEO工作台

W2保留Vista原生owner result/handoff语义：Snapshot中的可选governance只是有界消费副本，绑定、阶段、run/session/revision/head、result decision/outcome/reasonCode、交接引用和currentVerification原样受限展示。`deliverable`只称该stage原owner已接受；`subagent-output-available`不是任务验收，`source-shared-delivery`不是安装/运行/业务完成。工作引用只按显式owner/kind/key归组，不把reporter session、cwd、名称或Todo关联升级为产品事实。

治理引用校验采用文件级预编译的安全metadata regex，避免在每条入站Snapshot的`Wire.validate`/`SessionStore.apply`路径重复编译5个模式；拒绝集合与Pi Vista owner `isSafeMetadataText`保持一致，binding/reasonCode等标识白名单不放宽。合成192引用、200次Swift wire decode/store的p95从基线约5.63ms降至约2.09ms；这是本机合成微基准，不代表滚动FPS。

Vista owner冻结memory-only出口`pi-vista:work-observation:query:v1` / `reply:v1:<requestId>` / `changed:v1`：准确hostSessionId、observerEpoch、seq、16条session-recent-observations及累计omitted。Desk启动一次读取、随后消费completed-observation通知，用户可明确“读取现有观察”；新epoch须通过关联query对账，旧epoch/seq/过期request拒绝，不轮询。每条原观察seq/observedAt保留，查询不刷新时间、执行原件IO/验证/模型/持久化，不另实例化factory或再调readOwner。原binding.sessionId可不同reporter，不强制对齐或自动跳到另一runtime。用户显式刷新会话状态也会读取一次内存出口；超时保留最后观察并标stale，不让旧数据冒充当前读取成功。该出口已在Vista PR71/source a06f7f33固定安装，Desk PR10/build73已用最终安装件完成SDK→Vista→Desk→Swift UDS验真（ownerReads1、extraOwnerReads0、原时间不刷新、provider0）；旧来源无响应仍保持unavailable，安装不代表旧业务会话已加载。

消费规格`pi-work-observation`复用既有Snapshot可选todo字段，任务权威仍在原生Todo。读取成功TaskDetails白名单id/subject/activeForm/status/blockedBy/owner；不读params/description/metadata/工具正文，敏感值及本机路径有限预检隐藏，不是完整DLP。最多512条输入、32条输出、任务行7KiB，状态计数与omitted/partial准确；无快照RPC时只前向观察，不另import模块状态或读历史。scope隔离clear/tree/compact，开始捕获范围、晚到和重叠快照不覆盖；observerSeq仅传输观测顺序，不冒充原生revision。

工作总览呈现原计划当前步骤、已记录完成数、真实输入提示与依赖卡点，已完成不等于verified/delivered，Todo.owner只是标签。无原owner work_ref/产品/nextAction/问题正文时明确未提供；本机分组不升级为产品事实，不按cwd/name猜。所有任务只内存展示，不入usage库或默认外发AI。查看/追加沿原生准确身份管理，关闭Desk不影响Pi；治理producer/结果/交接由pi-vista既有合同维护。

### 原生问题的可选关联

在既有InputNotice附加可选question元数据：caller-declared的PiWorkRef/stage与原owner epoch/seq/time，不复制问题、选项或答案。source来自原问题工具的`pi:work-question:v1`，legacy `pi:input-required`不变。两条事件共用完整toolCallId散列后的输入ID；新关联只更新同一行，不再提醒/重置已读。工作声明不认证归属，缺/坏关联明确unbound/unavailable，仍回原入口作答。

原owner的opened/answer-received/closed只影响输入生命周期，收到答案不等于决定已应用或业务完成；Legacy end依旧能关闭输入，不把可选关联变成原流程前置。新事件按准确session/epoch/seq拒绝不适用数据，但无epoch的旧事件不具备该证明，完整replace/revoke/partial/跨负责人问题仍未完成。观察只在有界内存，输入列表预算和既有64KiB帧上限不扩大，无历史读取/模型/回答写口。

### 原生 mission 决策记录（消费端）

Snapshot可选missionDecisions只消费当前scope中成功subagent管理工具的公开ToolResult.details.mission。tool_result先按action与显式missionId匹配（mission.create的id由成功结果建立），最终tool_execution_end成功且白名单指纹/身份/原updatedAt一致后才发布；不返回结果patch。只取原decision id/status/createdAt/resolvedAt及mission id/schemaVersion/updatedAt，不读取或散列title/prompt/options/recommendation/resolution、missionPath或ownerSessionId。无新Vista端口、原件读取、状态库、模型回合或写入动作；初次加载及tree/compact/reload后未采集不等于零。

同一观察窗口保留原updatedAt时间水位：晚到旧记录不能覆盖新记录，相同时间但不同决策集合变为冲突未知，只有更晚原记录可解除；时间不是发明的revision。最多32个在途调用、16份工作记录，单份扫描512条并展示最多32条/2800字节，整体记录5400字节，整体wire仍64KiB。当前预算省略数与累计窗口移出数分开，后者不是去重后的工作数；已移出的身份不保留无限期时间水位。原记录更新不重排已保留工作的首次观察顺序。

同owner/kind/key只归组，各来源快照独立展示而不求和/替换；保留来源连接状态与原更新时间。open只称原记录未决，resolved只称原记录已解决；A解决B未决继续显示部分解决，绝不推导用户批准、全部问题答复或工作验收。无正文/选项/答案的回答UI，也不改变原InputNotice或needsInput。此片不关闭完整替换/撤销/迟答或自主恢复验收。

### Intercom 原生传输关系

Snapshot可选intercomRelations仅被动观察当前scope中原生intercom status工具成功ToolResult，既有tool_result核action/请求messageId，最终成功tool_execution_end核白名单投影一致才发布。没有新增查询、bus、Intercom实例或历史扫描。原owner来源是MessageStatus.relations v1与既有status details；只取messageId、delivery/outcomeKnown/replyState/updatedAt及relations的version/senderSessionId/recipientSessionId/supersedes/supersededBy/replyTo/lateReplyTo/replyCorrelation，不读content/reason/maintenance/正文/答案。原ID按owner ASCII字符规则（允许冒号、首位字母数字、最多128、无双点）及本机敏感值过滤，不截断。

sender/recipient是原broker路由ID，不要求等于Pi native session；不同reporter独立，不造workRef、关系图或消息任务库。matched仅原回复关联已匹配，late仅迟答未匹配等待；none不是业务未答，unknown或缺关系/旧broker保留未知。传输关联不代表业务答案适用、授权、撤销或工作验收，不进入InputNotice/需要用户，也不因UI关闭或mission.resolved生成关联。

每runtime最多32个在途调用、16条状态内存记录、5400字节显示预算，从原display总预算扣除，wire仍64KiB。保留原updatedAt，窗口内旧时间不能覆盖新记录，同时间不同投影标冲突未知，只有更晚原件解除；缺时间不清水位。scope在tree/compact/session/reload失效，当前省略和累计窗口移出分开；被移出的身份不保留无限期水位，未观察不当零。会话原工作详情折叠展示逐条原ID、关系、原时间和来源非实时提示，没有管理写入按钮。

## 12. 验证与退出策略

取消正常退出时保留连接和定时维护，teardown只在applicationWillTerminate执行；冷入口命令先建立管理窗宿主再呈现sheet。启动恢复将AI累计/分组与导航偏好分开：早期导航不跳过持久数据，早期AI数值按饱和加法合并增量，分组只覆盖明确编辑的键（含删除）；合并超容量时保留旧分组并提示重新设置，不默认清空。

先fixture协议/reducer/统计与原生faux SDK，再两个隔离会话+子任务，最后按实际授权本机验收。断App、满队列、旧epoch、重复点击、回复丢失、父子重复统计和未知owner都必须有负例。

初始性能目标为实现候选：观察handler不含I/O等待；合成负载下新增同步工作p95≤1ms、p99≤5ms；在至少1000事件及既定会话规模下与关闭桥接比较耗时/内存。阈值不是已测事实，超出先优化观察接线，不能换低能力模型、减工具或加审批过线。

源码候选阶段只做旁路 ad-hoc 构建；后续用户明确授权的本机安装沿同一源合同进行，安装不等于对外发布或业务会话热更新。后续回退只退出App、按原扩展加载方式移除本扩展；不能结束Pi、清理他人状态或倒退原owner版本。发行更新需单独验证App身份/签名、独立更新源和卸载影响。

本机稳定安装采用用户Applications下的固定App，以及用户Application Support中以source commit命名的只读bridge版本。bundle内BuildInfo固定source tree/commit、version/build和bridge逐文件hash；自动发现入口只选择该固定版本，不改Pi settings或既有工具/模型配置。安装manifest和定向备份是安装/回退资料，不承担会话/任务/调度状态。旧runtime继续持有旧桥接，更新/回退不强reload或结束Pi。
