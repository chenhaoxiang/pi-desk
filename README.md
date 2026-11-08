# Pi Desk

**看清 Pi 的运行，管理正在进行的工作，不打断自动化。**

Pi Desk 是 Pi-only 的轻量 macOS 原生可视化与管理客户端。它连接已经运行的 Pi 会话，不是另一个 Agent 宿主、终端、调度器或审批中心。

## 当前状态

Pi同源工作台首批正在实施：新增工作总览和原生Todo只读清单，来源为当前准确Pi运行的成功结构化任务结果，显示当前步骤、原计划完成数、依赖卡点和真实输入等待。不新增任务数据库、模型回合、审批或执行器；首屏无当前快照RPC时明确“未采集”，旧bridge不强制reload，产品/work归属与owner结果未接前不猜测。长期分工和W1–W4路径见[实施方案](docs/implementation-plan.md#0-pi同源ceo工作台与自主推进路线2026-11-05)，消费规格见`openspec/changes/pi-work-observation/`。源码/验收/安装仍分别核对。

2026-11-04 流畅度修复候选：针对真实主线程采样中的会话列表重复排序和SHA256格式化热点，复用有界内存派生投影与偏好键，快照/筛选/分组/别名等变化正确失效；不删功能或降低Pi执行。AI页短时间重入复用模型目录，显式刷新仍立即重读。合成64行投影基准与真实滚动帧率分开说明，实际交付版本以PR/安装verify为准。

2026-11-04 后续修复：**AI模型选择不再依赖旧活跃会话是否已加载AI桥接。** 优先使用本机已安装Pi公开SDK按需读取注册且可用的模型目录，模型以provider/model成对选择，思考强度按该模型能力选择；不自动降档或改业务Pi。一次性无工具SDK分析与业务会话分离，不创建AgentSession；无网络恢复Pi已缓存目录。本机目录探测失败可降级在线目录，但unknown分析不重发；取消/关闭UI后SDK进程允许短暂安全收尾，避免打断共享OAuth续期保存，不强杀进程。旧bridge的来源可明确使用元数据/手动补充，近期原文仍要兼容bridge，不能绕过为历史文件读取。AI来源主标题使用Pi原生`/name`，不被Desk本机别名覆盖；快照与原生改名事件会更新名称，旧运行未上报则明确提示，不强制reload。实机注册表只读核对得到44个可选模型，没有发起推理；构建/安装/GUI结果仍以本次PR与verify证据为准。

2026-11-04：**通知/健康/草稿/命令面板、顶部策略与可选AI基座已实现为增量候选。** 通知点击使用私有哈希绑定准确runtime并处理冷接入/过期；接入健康分层说明；未发送草稿及AI补充说明在正常退出时默认保留，⌘K统一导航和固定动作；工作分组仅是本机标签，顶部支持仅菜单栏/自动/默认固定及屏幕策略。AI默认`codex-local-8319/gpt-6.1-sol`、`medium`，可修改；只有明确请求才推理，通过兼容在线Pi注册表旁路提供有来源的总结/分组建议，不修改业务模型、工具、执行状态或历史。按用户选定范围读取所选当前分支有限近期用户/助手文本，提供预览/移除及敏感值预检，不扫描历史目录。**原版本无在线兼容bridge时AI不可用；上述后续修复已解除模型目录和元数据分析对此入口的依赖，近期文本读取仍按bridge能力降级。不强reload旧Pi。** 默认模型已以合成上下文完成一次真实SDK请求，费用未估算；其余回归均使用faux provider。候选、合并、实际安装及系统现场交互分别核对，当前交付以PR和安装verify记录为准。

2026-11-03：**三轮日常体验优化已实现并通过适用原生、bridge 与合成 SDK 检查。** 会话改为紧凑稳定列表，支持可搜索的本机别名/置顶；顶部速览优先需关注对象且展开期间不挪动目标；新增真实事件活动时间、本轮结束未查看提示与分级重要事项，操作反馈按 runtime 绑定；详情和设置分层，Token 可展开同口径前期对比，缺失记录不伪装为下降。旧 bridge 自然加载前缺少新活动字段时显示未知，不强制重载。原生合成窗口已做深浅色/64条列表等渲染复核；当前 Cua 后台 AX 绑定受限，不宣称全控件交互或新版 VoiceOver 现场重验。本机实际安装 source/build 以安装器 `verify` 和 App `BuildInfo.json` 为准，正式发行边界不变。下面保留上一版本的交付快照。

2026-10-30：**v0.1 本机交付已收口，非正式发行。** SwiftUI/AppKit + TypeScript 已实现顶部速览、中文管理窗口、私有 UDS、准确执行/输入状态、Terminal 跳转、原生消息/中止、owner 子任务与计划和持久 Token 总统计。本机保留唯一稳定应用 **0.1.0 build46 / runtime source `506174c`**，安装字节、bridge 与 ad-hoc 签名已验证。源码 PR #1、#2、#3 均已合并，`506174c` 的真实 CI 已通过；本轮仅整理文档和本机副本，不为文档重建 runtime。

2026-10-29，用户在系统授权回读与测试通知受理后，现场明确确认通知可见、VoiceOver 能朗读并遍历会话列表及关键设置控件；这纠正了 10 月 28 日的 denied/未验结论，保留早期失败作为历史，不把当时 build38 的现场确认改标成 build46 的全面重验。多会话、Terminal 精确定位、代表性键盘、小窗及内外屏证据见[实施记录](docs/implementation-plan.md#6-本地实施与证据层级)。

**Herdr 正向实机跳转仍未验证**：本机没有已配置宿主。既有规格要求无效/缺失路由明确失败、不跳错对象；解析与缺失/多匹配负例有检查，不能据此声称 Herdr 实机成功，也不为清单安装未知宿主。当前本机支持路径据此收口，保留该兼容边界。签名公证、自动更新和对外发行尚未执行；源码合并、本机安装与正式发行分别记录。旧业务 Pi 不强制 reload，历史 usage 不重复补采。

## 构建和合成检查

需要macOS14+、Swift6工具链和Node22.19+（本机测试Node26）。本轮开发SDK基线为1.5.0；旧宿主缺少新注册表API时只降级AI。下面默认合成检查不需要真实模型密钥、不调用真实provider；指定模型真实验真是独立显式维护动作，不进入CI。安装/验证/回退入口直接使用Node对`.ts`的内置类型剥离，不要求先安装`node_modules`或`tsx`；测试、类型检查和native SDK检查仍需先安装开发依赖。

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run check
npm run test:native-sdk
bash scripts/check-native.sh
node --import tsx scripts/check-socket-host.mjs
bash scripts/package-app.sh release
```

原生检查使用 Foundation 可执行检查 runner，因此只装 CommandLineTools 时也可运行，不要求额外安装 XCTest。构建产物位于 `tmp/candidate/Pi Desk.app`，采用独立 `io.github.chenhaoxiang.pi-desk` 身份和 ad-hoc 本机签名；内含 version/build/source tree/commit 与 bridge 文件哈希，没有公证或自动更新。dirty 源码构建不能进入稳定安装。

真实 owner 组合检查是显式选择的本地测试，不读取业务会话：设置 `PI_DESK_SDK` 为已审核 SDK 包根、`PI_DESK_SUBAGENTS` 为已审核 Subagents 包根、`PI_DESK_SCHEDULE_PROMPT` 为带管理 seam 的 Schedule 源码候选根，再运行 `scripts/check-subagents-native.mjs` 或 `scripts/check-schedule-native.mjs`。这些检查创建自己的合成会话、faux provider 和临时产物；不能用缺少 seam 的已安装 Schedule 版本冒充候选。

## 稳定本机安装与回退

安装/回退前正常退出本 App，保留未发送草稿；`verify` 只读核验，无需退出。没有可复用产物时，先在 clean 的已验证源码上构建 release，再显式安装：

```sh
bash scripts/package-app.sh release
node scripts/install-local.mjs install
node scripts/install-local.mjs verify
```

已有 clean release 产物时，仅在 `BuildInfo` 的 sourceCommit、sourceTree、配置及构建输入与本次已验证版本一致时复用，不因换目录或进入安装阶段重复构建。若本次要求绑定 merge SHA，sourceCommit 必须为该 merge；不能仅凭 tree 相同给旧产物改标。产物缺失或输入变化才补受影响的构建与验证，安装器的签名、字节和 hash 核验始终保留。

- App 固定在当前用户的 `~/Applications/Pi Desk.app`，随附 `Contents/Helpers/PiDeskPeerCheck`；首次可从 Finder 打开，不要求管理员权限，不关闭系统保护。
- Bridge 固定在 `~/Library/Application Support/PiDesk/bridge/<source-commit>/`，内容按 manifest 校验并设为只读，不指向 worktree/tmp。普通 Pi 通过 `~/.pi/agent/extensions/pi-desk-bridge.ts` 自动发现这一固定入口；无需每次设置 helper 环境变量或 `--extension`。
- 不改原 `settings.json`、模型、思考档、工具、prompt 或权限；已运行的会话不强制 reload，待新会话/安全自然加载才接入。显式 `--no-extensions` 或原资源排除规则继续生效。
- `install-current.json` 只记录 App/bridge 安装字节与上一版回退位置，不保存任务、对话或凭据。安装器只替换可核验的本工具已管理版本，未知/被改写的目标保全并报错；更新前退出本 App，Pi 无需退出。
- 首次安装的回退是退出 App 后运行 `node scripts/install-local.mjs rollback`，只移除受管理的 App/入口与当前安装记录；有上一版则恢复其准确字节。已有 Pi 不被停止，旧的固定 bridge 版本保留以免破坏已加载会话。未知目标和其他 Pi 设置/组件不清理。
- Schedule seam 仍只是独立候选，不随 App 偷装/升级全局 Schedule，也不启动常驻监督。未配置/旧 owner 的可选能力按实际 unavailable 展示。

2026-10-30 本机按用户要求只保留上述稳定 App，已清理受管理旧版、构建候选和视觉预览副本，并解除旧 App 回退引用；**该本机安装不再提供旧版 App 一键回退**。这不删除用量库、会话、历史导入备份或旧固定 bridge；已加载 Pi 仍可继续使用旧 bridge。安装器未来更新的默认备份行为未在本轮修改。

安装状态以 `verify` 的 byte/hash 回读和实际 App/新会话证据为准；写文件、源码检查、安装、进程运行与新会话已加载分别记录。

## 一次性历史用量补采

这是2026-10-26明确授权的单次维护动作，不是启动/刷新功能或历史对话浏览器。`scripts/history-backfill.py preview` 冻结 canonical Pi JSONL 文件集合与前缀哈希，低优先级单worker流式投影 assistant/usage/compaction/branch-summary 的四桶元数据；`apply --run <private-preview-dir>` 校验冻结输入并事务导入。正文、工具参数/结果、原会话ID/路径不进入stage、收据或输出。

导入与实时共用消费键；fork/clone沿parent链和entry ID+usage fingerprint解析，缺链/冲突保守跳过，未知物理模型不猜成当前模型。维护时正常退出App，Pi继续记录spool；使用SQLite backup API包含WAL的一致快照及owner-only备份/收据，重复apply不再写入。`rollback --import-id <receipt-id>`只移除此导入新增且未被后续实时确认的记录，不覆盖后来实时数据；App版本回退是独立动作。实际用量与备份路径只保存在本机私有证据。

## 开发态显式接入（仅在你选择的隔离会话中）

先手动打开本地候选，再从本仓显式加载扩展：

```sh
PI_DESK_PEER_CHECK="$PWD/tmp/candidate/Pi Desk.app/Contents/Helpers/PiDeskPeerCheck" \
  pi --extension ./packages/desk-bridge/src/index.ts
```

默认 socket 在当前用户的 `Library/Caches/PiDesk/runtime/desk.sock`；可通过 `PI_DESK_SOCKET` 和 App 的 `--socket-path` 指定相同的隔离路径。App 的 `--settings-path` 可将本 App 设置放到独立测试目录。桥接不会自动安装、启动 Pi、选择模型、修改思考档或增加工具。

`PiDeskPeerCheck` 是随 App 打包的有限 UID 检查助手：Node 通过公开的子进程 stdio API 传入已经连接的 fd，助手只执行 `getpeereid(3)` 后退出。没有另一个 Agent、守护进程或网络服务。缺少助手、UID 不符或路径不安全时，只有观察连接不可用，原 Pi 继续运行。

## 日常可视化与操作

- 顶部胶囊是日常入口：悬停或点击展开，pin固定展开；离开延迟收起，编辑时保持。Escape先退出编辑，再收起非固定面板；普通状态事件不自动弹大窗或抢焦点。
- 会话/项目名和中文状态优先；未命名会话有稳定区分，详情标题旁可设置仅本机显示名或置顶，别名可搜索。默认列表不随运行状态跳动；顶部展开优先待输入、异常、未查看变化与关注对象。追加要求、纠偏就近按需展开，不用一直面对空白表单。危险的“中止当前回合”放在更多操作中。
- 诊断保留source/epoch/runId/覆盖原因，但不占主层；未知、部分覆盖、较旧或断开仍有可读提示。
- 管理窗跟随系统深浅色，顶部固定深色；动效尊重减少动态效果。无刘海/外接屏用顶部胶囊，camera/safeArea不需要屏幕录制或无障碍授权。
- 原生合成预览脚本 `scripts/create-visual-fixture.mjs` 仅生成明确synthetic记录；`--visual-fixture` 模式不连接真实会话、不保存真实设置、不递送真实管理请求。

## 使用边界

- 追加/纠偏走原生 `sendUserMessage`；该 API 返回 void 时只显示 **requested**，不伪造 queued/accepted。
- 中止当前回合不清空后续队列、不停止独立子任务或外部副作用。Subagents stop 受理与进程终态分开。
- Subagents Fleet key 只展示；后台孩子控制从 owner 的公开定向状态取得真实 runId。resume 由 owner 验证资格，拒绝后不偷开替代任务。
- 计划按 owner 分开。Schedule seam 只复用现有 list/pause/resume/delete 和 event-job trigger，不新增计划库、CRUD 或常驻服务。暂停未来触发不撤销正在执行的工作。
- 真实活动时间只来自生命周期/工具事件，心跳不冒充进展；结束提示不代表业务完成，已读/已查看不回答问题或继续执行。旧 bridge 没有事件时间时显示未提供。
- 侧栏增加AI助手与接入健康；⌘K打开命令面板，⌘4/⌘5打开健康/AI，草稿与工作组管理从固定动作进入；子任务与计划并入准确会话详情，保留数量、空态、owner/覆盖和未来触发语义。⌘1/⌘2/⌘3、⌘F与下一需关注会话只用本地状态，不发owner轮询。
- Token主页面为跨已记录会话的“Pi总用量”：今日/近7天/本月/自定义时间、趋势和模型分布；自定义最多400天（含首尾日期），超界明确提示并保留上次有效结果，不静默截断趋势。从启用记录起异步持久化final标量，App关闭仍记录，重开恢复；另按2026-10-26授权执行一次Pi历史usage元数据补采。实时/历史/去重合计分开显示，不将owner累计补记为今天，不重复父子/工具聚合。缺失保留已知下界与覆盖缺口，不等于套餐额度/账单。
- owner执行后失败/超时为 unknown，不解释成确定未执行、不自动重试。本地请求未能提交时保留草稿。
- 提醒已读/静音只改表现，不回答问题、不阻断执行。原 producer 通知从不被本客户端静默抑制。
- 原会话定位只接受主动接入快照里的精确 Herdr pane 或 Terminal.app TTY route（唯一匹配后才聚焦；tmux/WezTerm/cmux未接入或Automation拒绝即不可定位）；不按cwd/名称猜窗口，不对活跃会话自动执行`pi --session`开启第二writer。旧bridge缺route时可从当前UDS peer的PID/出生时间/TTY作有界精确定位；缺执行proof仍明确状态待核，不把连接在线当作AI忙闲。管理页仅允许用户配置的无凭据、无 query/fragment 的精确 HTTPS 地址。
- 会话卡片的创建时间只来自session header timestamp，缺失/超界显示unknown，不把observedAt或首次接入时间当创建时间。
- 设置页仅投影Pi原生用户settings.json白名单：theme、thinking、steering/followUp、compaction、retry、quietStartup、tuiMode和终端图片/进度；项目`.pi/settings.json`只显示覆盖来源，不写；auth/models/MCP/资源/代理/信任/权限和工具模型默认值不纳入。写入带Pi兼容的`.lock`目录、revision冲突、owner-only备份、原子替换和readback，失败只读保全。
- 关闭、断联或结束 Pi Desk 不结束 Pi；不常驻扫描历史，不发现旧会话卡片，不读终端文本或凭据。仅显式授权的一次性补采worker只读Pi JSONL并立即投影usage标量，不保存/输出原正文或路径。

## 文档和规格

- [产品范围与验收](docs/product-v0.1.md)
- [架构、协议及统计语义](docs/architecture.md)
- [接口与实际接线](docs/integration-matrix.md)
- [交互及原生检查范围](docs/interaction-design.md)，[原始静态设计稿](docs/design/pi-desk-v0.1.html)
- [实施记录、验证与未完成项](docs/implementation-plan.md)
- [现行行为规格](openspec/specs/)
- [首版归档与任务](openspec/changes/archive/2026-10-30-pi-desk-v0-1/tasks.md)

现行合同可用官方全局 CLI 检查：`openspec validate --all --strict --no-interactive`。首版由官方 CLI 归档并提升三项行为规格，没有跳过校验；文档/spec 通过不是额外业务或发行验收。

## 与 CodeIsland 的关系

这是独立新仓，不是完整 fork；当前外壳和适配是本仓实现，**没有复制 CodeIsland 源码、图标、动画或品牌素材**。没有继承其签名、公证、发行或更新身份。依赖 Pi 与各 owner 的公共接口，不重新分发另一套 Pi 宿主。
