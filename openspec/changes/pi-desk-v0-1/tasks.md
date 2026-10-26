# Tasks

按实际源码与验证更新；未勾选项仍未达到该项全部验收，文档/静态稿不算运行功能。阶段说明见[实施方案](../../../docs/implementation-plan.md)；行为要求只维护在本Change三项spec，具体架构和界面各有owner文档。

## 1. M0 合同与工程骨架

- [x] 1.1 建立最小SPM App/Core/Transport与TS bridge包，验证Swift build、TS typecheck和公开入口文档，不加入新Pi宿主或daemon。
- [x] 1.2 冻结wire v1的身份/epoch/seq、能力与动作枚举，建立双端一致的合成fixture，验证半包/非法/超限/未知字段/不匹配主版本负例。
- [x] 1.3 建立不修改prompt/tools/model/effort/规则与不注册新模型工具的隔离宿主断言，验证bridge关闭和开启基线参数一致。
- [x] 1.4 配置最小合成测试/泄漏检查及原生build入口，核实实际runner/权限；验证CI不读取真实凭据、不调用模型、不安装全局扩展，记录尚无原生执行器时的缺口。

## 2. M1 在线会话可视化

- [x] 2.1 实现session_start登记、session_shutdown幂等清理和私有UDS连接，验证无App时Pi照常启动、factory不建资源、无历史/进程扫描。
- [x] 2.2 实现白名单snapshot/reducer、重连/旧epoch/乱序拒绝与drop标记，验证固定fixture跨语言结果一致。
- [x] 2.3 实现非阻塞有界生产/消费及退避，验证慢读/断联/满队列情况下原工具不等待、内存有界；记录p95/p99与原轨迹差异。
- [ ] 2.4 实现顶栏与管理窗口的会话列表、详情和准确跳转，验证键盘/VoiceOver/无刘海/外接屏及无效路由不跳错对象，更新交互文档。
- [x] 2.5 接入agent_settled、原生pending、实际UI等待和owner子任务投影，验证agent_end后续行、自动恢复、多会话及前台/后台孩子不误报完成。
- [x] 2.6 提供scope明确的接入窗口usage，验证流式只结算一次、部分coverage和重载新窗口；不将M1观察结果标记为完整v0.1交付。

## 3. M2 原生管理闭环

- [x] 3.1 在有效当前context实现直接Pi follow-up/steer/abort-current路由，验证准确身份/epoch、真实原生队列与既有工具不中断，不伪造durable受理。
- [x] 3.2 接入Subagents ping/status/steer/stop/resume并按capabilities开放，验证runId与display key分离、归属和恢复资格、当前会话范围，缺owner时原任务继续。
- [x] 3.3 实现action request/结果/operation-update与有限去重，验证重复点击、丢回复、runtime替换不重复派发，不新建业务账本或盲重放。
- [x] 3.4 完成两个隔离Pi及一个owned子任务的faux-native管理闭环，验证请求中止/停止受理与实际终态分开、未命中对象继续运行，更新用户操作说明。

## 4. M3 Token与已有计划

- [x] 4.1 接入可用owner native累计/Subagents cost报告及coverage，验证settled/async完成/用户刷新才有界取数，App不读原会话文件、不周期扫描artifact。
- [x] 4.2 建立usage黄金fixture，验证input/output/cache、compaction/summary、nested usage、fork继承、父子双卡、未结算和owner下界；无归属不报精确总计，更新统计说明。
- [x] 4.3 接入Subagents schedule管理allowlist，验证owner命名空间、暂停未来触发不伪称停止当前运行以及不存在/过期目标负例。
- [x] 4.4 依据当时实际实施授权，在Schedule owner补最小公共在线管理seam与其测试（若仍缺）；验证不越过原session绑定/限额/存储规则，不在Pi Desk直接修改JSON；否则明确未完成的能力边界。
- [x] 4.5 本候选不走跨peer outbox：精确管理直接命中主动接入的Pi；未把Intercom v1当wake/mode支持，未改变原消息默认行为。后续若确需非接入peer的精确递送，再由Intercom owner补合同与测试。

## 5. M4 注意事项与治理入口

- [x] 5.1 接入实际ui_prompt/question生命周期、提醒已读/静音和准确跳转，验证关闭提醒不代答/取消原问题，generic custom不误归属。
- [x] 5.2 实现通知来源/稳定事件关联与原兜底，验证接管失败/重复事件不会吞提醒、禁用执行或重跑业务；更新通知说明。
- [x] 5.3 建立可选治理/Gate/CI安全reader与合成fixture，验证事实/建议/unknown、head/freshness与merge/post-CI分离，未接真实producer明确显示未配置。
- [x] 5.4 提供用户配置的精确现有管理页入口，验证链接scheme/目标、无任意shell和凭据复制，未配置不影响Pi核心功能；不复制完整控制台。

## 6. M5 完整首版验收与候选打包

- [x] 6.1 运行实施方案A1–A11组合矩阵，验证相同fixture的新增模型调用/人工确认0、原参数/执行结果不变，记录UI断联/崩溃/背压/更新影响与实际性能。
- [x] 6.2 核验固定Pi/owner版本及缺少owner/混合版本模式，验证TUI现有能力不因接入被降级，不强reload真实业务会话。
- [ ] 6.3 在已授权的精确隔离本机目标中做原生多会话/输入/跳转/通知验收，区分合成与真实证据，不读取真实历史日志充当fixture。
- [x] 6.4 构建旁路候选、验证卸载/回退只移除本App与本扩展，记录独立App身份、许可、签名/公证/更新源及尚未执行项；无授权不安装/发布。
- [x] 6.5 核对所有首版范围、管理能力与证据层级，更新README和产品状态；验证没有把观察里程碑、source通过或静态预览冒称完整首版/已上线。

### 当前仍未满足的组合验收

2.4 已有原生窗口/顶栏和AX/双会话GUI，Herdr实机、完整键盘/VoiceOver及6.3实际OS通知仍未验；build18以显式合成预览核对真实刘海内屏和无刘海外屏compact/expanded及跨屏跟随，不冒称所有系统组合。6.1–6.2已按原A1–A11、固定支持版本及代表性旧/缺失/混合cap补齐；不以所有历史owner、长期provider或24x7另造前置，亦不把软件通过冒称现场系统通过。6.4 已有release ad-hoc候选和实际kill/重启隔离检查；新增获授权的本机稳定App/固定bridge安装、自动发现和回退验证，hash与安装事实保存在本机manifest及本树tmp验真产物；6.5 已如实更新源码/验收/安装状态，不归档Change或宣称完整v0.1。详见实施方案第6节。

## 7. Native visual and interaction refinement

- [x] 7.1 实现顶部AppKit panel的compact/expanded、hover/click/Escape/pin/edit保护与camera/safeArea/普通屏fallback；不加权限或自动抢焦点。
- [x] 7.2 实现中文状态/图标/色标与层级卡片、准确工具/子任务摘要、按需追加/纠偏、后置诊断；未知/partial/断联保留可读提示。
- [x] 7.3 以显式合成fixture核对原生compact/expanded/管理窗、长名/空/断/多会话、Escape编辑保护与Reduce Motion，并验证准确epoch管理目标不串线；Tab焦点遍历尚不可证，完整资格仍留2.4/6.3。
- [x] 7.4 冻结视觉源码4f8846f/build 5，更新并验真稳定App与固定bridge，保留027572e/build 4准确安装回退；原生双会话追加仅命中A，不强reload业务Pi，不冒称完整现场资格。

## 8. 跨会话时间总用量与可操作性补齐

- [x] 8.1 固定持久final标量合同、UTC时间/本地日历半开边界与golden fixture；覆盖重复冲突/父子工具不重算/缺字段/旧来源。
- [x] 8.2 实现有界异步spool与App后台SQLite唯一索引，验证无App继续记录、重开恢复、并发/冲突/坏库/满队列和写盘失败可见；不读旧JSONL、不改主执行。
- [x] 8.3 实现默认今日的Pi总用量、近7天/本月/自定义、趋势与四桶/模型分布；未知日期留空、未来与覆盖缺口可读，会话只次级下钻。
- [x] 8.4 补实际会话搜索/状态过滤、仅隐藏断连卡片、刷新/更新时间与通知失败/权限状态，定向核对键盘/长名/大列表/主窗缩放/顶部多屏几何；实际不能验证项继续保留。
- [x] 8.5 运行适用SDK/生命周期/数据/原生验真，冻结source更新已授权本机稳定App、固定bridge并保留build5回退；不强reload业务Pi，不安装可选owner或扩平台。

## 9. 现场兼容窄补齐

- [x] 9.1 将A1–A11/6.1–6.2逐行绑定证据与缺口，补旧wire无记录器/受限cap/旧或缺owner局部降级fixture，不强reload业务Pi。
- [x] 9.2 增加仅显式点击的系统通知授权入口和fake授权/拒绝/错误/发送失败检查，真实OS consent保持用户决定，不新增执行门禁。
- [x] 9.3 非法custom日期不查询/不改义并保留旧聚合及在途保护，补calendar同日边界与真实原生提示。
- [x] 9.4 已运行600.005s独立PTY/实际InteractiveMode/faux soak：58轮、12次工具续行、5次receiver重启/15离线轮、140 final与A/B 82/58一致；不假称完整业务TUI资格。
- [x] 9.5 已安装62277d8/build9并保留ad09e82/build7准确回退，回读签名/hash/实际通知按钮和日期合成提示；Herdr/VoiceOver/真实系统投递继续保留。

## 10. 真实运行界面与统计语义核修

- [x] 10.1 真实稳定App核对SessionList的在线/全部/断连/搜索/选择空态，修可见计数、长名和默认断连呈现，避免过滤外详情误操作。
- [x] 10.2 将用量总览拆为交互Token、缓存复用/写入、四桶记录总处理量；趋势/数据表/模型分布共用交互/缓存/全部口径，补独立算式和真实metadata-only回读。
- [x] 10.3 更新并验真固定source稳定App，保留build11回退；真实Herdr/VoiceOver/OS通知投递等仍不冒称。

## 11. GPT采集根因与性能边界核修

- [x] 11.1 metadata-only核真实在线GPT旧bridge、usageRecorder与拒绝边界；补fresh GPT-named faux final→spool→SQLite→model分布，旧会话未自然加载时明示不纳入。
- [x] 11.2 移除settled/async自动owner cost扫描，按当前对象/显式刷新限频，补固定owner大branch同步RPC耗时和同faux/PTY dispatch/turn/RSS/pending对照。
- [x] 11.3 App保持单utility ledger连接/dirty cache/rowid增量/model filter；复现并严格恢复自有hard-link crash temp，未知第二链接不删。
- [x] 11.4 已安装40bce16/build16，实际canonical GPT final/recorders/SQLite与模型过滤分布可见；旧GPT会话仍有缺口，Herdr/VoiceOver/OS consent和长期provider资格未冒称，不强reload业务Pi。

## 12. 一次性Pi历史usage元数据补采

- [x] 12.1 实现canonical Pi JSONL只读preview/apply/rollback worker：冻结文件dev/inode/size/prefix hash与source-set hash；低优先级单worker、分块流式、有界行/内存、节流；stage/收据只保存usage标量、模型/时间/消费fingerprint和安全摘要，不保存/输出正文、工具参数/结果、原路径或原会话ID。
- [x] 12.2 与实时共用host/session/entry消费键；覆盖所有分支、assistant final、explicit usage kind、compaction/branch summary，reasoning/cacheWrite1h不重复；fork/clone沿父链和fingerprint建alias，短ID不全局化，缺父/循环/冲突保守跳过，unknown不猜物理模型。
- [x] 12.3 apply前正常退出App但不停止Pi，使用SQLite backup API含WAL的一致快照、私有owner-only补充备份和receipt；新增provenance/import/alias/conflict表保持旧八列兼容，重复apply无变化，目标回退只移除本import新增且保留后续实时确认/审计事实。
- [x] 12.4 Swift Ledger/UI支持实时记录、一次性历史补采、去重合计来源切换；来源覆盖日期、缺字段/未知模型/跳过原因、模型/趋势/四桶口径一致；启动/刷新不自动扫JSONL。实际canonical preview/apply、数据库quick_check、私有备份、重复apply、fixture全套与来源分区回读已验真。
- [x] 12.5 对原A1–A11/6.1–6.2补齐实际Pi 1.4.0-fork.1/Subagents 0.80.0-fork.1/代表性旧缺失混合cap：native retry/threshold compaction/queued continuation bridge开关对照、loadout/模型调用/确认/settled边界不变；2.4/6.3的Herdr/VoiceOver/OS consent/实体多屏仍分别标未知，不作为历史补采阻断。

- [x] 12.6 冻结138938f/build18并完成稳定install/verify、签名、真实canonical来源切换/收据/覆盖日期/metadata-only SQL四桶回读；保留build16安装回退和独立历史import回退，真实用量/备份路径只留本机私有证据。用显式合成预览补真实内屏safeTop32/gap185与外屏safeTop0/gap0及跨屏panel跟随，不改变系统设置，临时预览已退出。

## 13. 统计首屏与真实大库性能

- [x] 13.1 收紧时间/来源/模型/刷新工具条，去重复标题、来源三列大数与同值重复；当前metric单一主数、四桶小拆分、175pt趋势紧随，来源/覆盖/导入收据默认折叠，错误/unknown/pending仍有短提示。
- [x] 13.2 本App真实窗口visible/occlusion/minimize/close兴趣驱动5/30/60秒统计刷新；Pi异步采集不变、无owner自动查询。utility最多3范围缓存、源/模型投影、单合并请求、empty spool无写事务，图表按bucket等值复用。
- [x] 13.3 记录真实大库metadata-only进程累计CPU/IO/RSS前后30秒和同scope暖响应/cache/增量，按统计可见/其他页/AX确认最小化/AX确认关窗分段；实际输入行差异和未证明改善如实保留，不重新扫描源JSONL。
- [x] 13.4 冻结`8bd2e80`/build20、稳定安装并保留build18，verify/codesign/runtime回读；标准/960小窗、长模型、自定义unknown、深浅色、source+metric截图和真实canonical ledger cache evidence已留本机tmp。未push/PR/发行，不扩大未变Pi后端验收。

## Workflow follow-up

- 共享源码交付按当时适用的独立只读审查、PR、检查和普通merge流程；空仓首main的初始化需匹配实际授权，不默认直推。
- 安装、真实启用和发行只按对应范围连续推进，不把本Change的存在当额外批准或操作许可。
- 本Change只在真实实施与适用验收完成后归档；规划产物齐全不等于任务完成。
