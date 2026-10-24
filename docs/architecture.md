---
doc_type: plan
project: workspace
owner_repository: chenhaoxiang/pi-desk
product_line: pi-desk
release_scope: 本地实现候选；完整首版验收仍未完成
status: active
truth_mode: maintained
created: 2026-10-24
verified: 2026-10-24
verification_scope: Swift/TS源码、UDS/隔离真实SDK与owner组合；不含业务会话/Herdr实机和长时可靠性
---

# 系统架构

产品边界见[产品范围](product-v0.1.md)，具体接口及版本见[矩阵](integration-matrix.md)，行为要求统一在[单一 Change](../openspec/changes/pi-desk-v0-1/proposal.md)。本页是实现结构与取舍，不是新增治理权威。

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
- **UDS + 有界LF-JSON协议**：无HTTP端口、WebSocket服务、跨网发现和数据库。Native socket读取在后台串行队列，UI只接收合并后的不可变快照。
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
openspec/changes/pi-desk-v0-1/
```

`Sources/PiDeskPeerCheck/` 是有限 syscall 助手，不是第三个运行宿主：在桥接的异步连接验证阶段经公开 stdio 传递 fd，仅执行 `getpeereid` 并退出。它随 App 打包，缺失/失败只使该观察连接不可用，绝不替换为不验证 peer 的连接。

不提前建立第三个协议SDK包；跨语言共享wire fixtures和封闭schema，编译实现只放两端必要结构。

## 3. 状态与身份

### 3.1 身份

主键是 `{localHostId, nativeSessionId, runtimeEpoch}`，epoch每次扩展runtime替换生成。会话名/cwd/PID/tty只作显示或经过验证的跳转信息，不作控制身份。

子运行使用owner `runId`与必要child index。Fleet display key只用于展示，不能转换成控制ID。Pi进程内多个会话不能用process-global parent变量当完整父子树；先用Subagents owner投影，环境字段最多是待核实提示。

App断线重连同一epoch，要求全量当前快照并保留monotonic seq；新epoch清除旧控制能力和未完成UI请求绑定。对旧epoch晚到的回复/动作拒绝，不把旧模型、状态或对象当当前。

### 3.2 分开保存的维度

| 维度 | 示例 | 不可推导 |
|---|---|---|
| connection | connected / stale / disconnected | 断联不代表任务失败或已停止 |
| execution | starting / running / retrying / compacting / waiting-children / settled / failed / aborted / unknown | settled不代表业务目标或所有外部工作完成 |
| attention | none / input-required / result-unread / warning | 未读不触发继续，不把idle视为需人 |
| management | ready / unsupported / unavailable + request状态 | 按钮可用不是授权或成功 |
| verification | not-checked / pending / verified / stale / failed / unknown | 显示的成功不生成merge/部署许可 |

`agent_end`只更新低层回合事件；最终闲置依`agent_settled`、原生pending与owner子任务/回传事实。没有子任务覆盖则保留unknown，不宣称全部结束。普通工具出错不自动把会话变成失败。

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
4. Subagents `cost`由原owner定向读取当前分支和关联运行产物，在settled、async完成或用户刷新时有界请求，不定时扫描。它可提供parent/children/childTotal/total和unresolvedAsyncChildren，直接保留来源与下界，不在App重算一份相冲突的总账。
5. `usage`、compaction、branch summary及nested tool usage必须与宿主归一规则对照。首阶段先建立合成合同，未覆盖的附加消耗明确标partial，不把只看assistant消息称完整账单。
6. same child既作为独立Pi注册又在父报告出现，显示可以两处关联，汇总只取一个owner归属；无可证明不重叠关系则不展示精确全局合计。
7. Context usage是上下文占用，不是花费；缺失/未结算值为null。无权威价格/费用结果不推算金额。
8. App只保留当前接入显示缓存；不做每日/历史账单数据库。重启后从已接入owner快照恢复当前scope，无法恢复的窗口明确重置。

## 8. 隐私、展示与诊断

默认白名单只含身份、状态枚举、工具名、计数、模型/effort标签及必要本机显示信息。项目/分支/本地路由属于私有display字段，只留当前用户内存，不写公开fixture、持久日志或外发通知。默认不传prompt、代码、命令参数、tool result、思考、会话正文或凭据。

用户主动输入的管理文本单独走action通道，只交给目标owner，不进入telemetry/历史/推送；终端仍保留原会话行为。源级白名单优先于通用正则，遇到异常数据只记录固定诊断码，不回显原件。日志仅版本、耗时、drop/error计数等安全aggregate；固定保留限额，默认不开原始数据导出。

通知从状态变化触发，不轮询LLM。保留现有通知兜底；只有原producer提供稳定事件ID且接管交付成功才抑制相应重复表现，首版无法证明时宁可保留原通知，不静默关闭它。静音/已读不写执行状态。

## 9. CodeIsland 复用决策

不整库fork、不导入AppState/ConfigInstaller/HookServer/多工具Discovery。对照快照中NotchPanelView约5764行、PanelWindowController约735行，不能假定抽文件即独立可用。优先以系统API重做小型外壳；ScreenDetector/动画/Herdr路由仅在依赖、维护收益和许可检查通过后局部复用。

真实复用时再增加归属与上游MIT许可，不现在预建空第三方体系。纯原创外壳与适配不假称继承上游签名、公证、自动更新或Buddy支持。

## 10. 验证与退出策略

先fixture协议/reducer/统计与原生faux SDK，再两个隔离会话+子任务，最后按实际授权本机验收。断App、满队列、旧epoch、重复点击、回复丢失、父子重复统计和未知owner都必须有负例。

初始性能目标为实现候选：观察handler不含I/O等待；合成负载下新增同步工作p95≤1ms、p99≤5ms；在至少1000事件及既定会话规模下与关闭桥接比较耗时/内存。阈值不是已测事实，超出先优化观察接线，不能换低能力模型、减工具或加审批过线。

当前只构建旁路 ad-hoc 候选和隔离 fixture；没有安装/发布/业务会话更新被执行。后续回退只退出App、按原扩展加载方式移除本扩展；不能结束Pi、清理他人状态或倒退原owner版本。发行更新需单独验证App身份/签名、独立更新源和卸载影响。
