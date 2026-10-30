# Pi Desk

**看清 Pi 的运行，管理正在进行的工作，不打断自动化。**

Pi Desk 是 Pi-only 的轻量 macOS 原生可视化与管理客户端。它连接已经运行的 Pi 会话，不是另一个 Agent 宿主、终端、调度器或审批中心。

## 当前状态

2026-10-30：**v0.1 本机交付已收口，非正式发行。** SwiftUI/AppKit + TypeScript 已实现顶部速览、中文管理窗口、私有 UDS、准确执行/输入状态、Terminal 跳转、原生消息/中止、owner 子任务与计划和持久 Token 总统计。本机保留唯一稳定应用 **0.1.0 build46 / runtime source `506174c`**，安装字节、bridge 与 ad-hoc 签名已验证。源码 PR #1、#2、#3 均已合并，`506174c` 的真实 CI 已通过；本轮仅整理文档和本机副本，不为文档重建 runtime。

2026-10-29，用户在系统授权回读与测试通知受理后，现场明确确认通知可见、VoiceOver 能朗读并遍历会话列表及关键设置控件；这纠正了 10 月 28 日的 denied/未验结论，保留早期失败作为历史，不把当时 build38 的现场确认改标成 build46 的全面重验。多会话、Terminal 精确定位、代表性键盘、小窗及内外屏证据见[实施记录](docs/implementation-plan.md#6-本地实施与证据层级)。

**Herdr 正向实机跳转仍未验证**：本机没有已配置宿主。既有规格要求无效/缺失路由明确失败、不跳错对象；解析与缺失/多匹配负例有检查，不能据此声称 Herdr 实机成功，也不为清单安装未知宿主。当前本机支持路径据此收口，保留该兼容边界。签名公证、自动更新和对外发行尚未执行；源码合并、本机安装与正式发行分别记录。旧业务 Pi 不强制 reload，历史 usage 不重复补采。

## 构建和合成检查

需要 macOS 14+、Swift 6 工具链和 Node 22.19+（本机测试 Node 26）。不需要模型密钥；检查不调用真实 provider。

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

先在 clean 的已验证源码上构建 release，再显式安装：

```sh
bash scripts/package-app.sh release
node --import tsx scripts/install-local.mjs install
node --import tsx scripts/install-local.mjs verify
```

- App 固定在当前用户的 `~/Applications/Pi Desk.app`，随附 `Contents/Helpers/PiDeskPeerCheck`；首次可从 Finder 打开，不要求管理员权限，不关闭系统保护。
- Bridge 固定在 `~/Library/Application Support/PiDesk/bridge/<source-commit>/`，内容按 manifest 校验并设为只读，不指向 worktree/tmp。普通 Pi 通过 `~/.pi/agent/extensions/pi-desk-bridge.ts` 自动发现这一固定入口；无需每次设置 helper 环境变量或 `--extension`。
- 不改原 `settings.json`、模型、思考档、工具、prompt 或权限；已运行的会话不强制 reload，待新会话/安全自然加载才接入。显式 `--no-extensions` 或原资源排除规则继续生效。
- `install-current.json` 只记录 App/bridge 安装字节与上一版回退位置，不保存任务、对话或凭据。安装器只替换可核验的本工具已管理版本，未知/被改写的目标保全并报错；更新前退出本 App，Pi 无需退出。
- 首次安装的回退是退出 App 后运行 `node --import tsx scripts/install-local.mjs rollback`，只移除受管理的 App/入口与当前安装记录；有上一版则恢复其准确字节。已有 Pi 不被停止，旧的固定 bridge 版本保留以免破坏已加载会话。未知目标和其他 Pi 设置/组件不清理。
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
- 会话/项目名和中文状态优先；追加要求、纠偏就近按需展开，不用一直面对空白表单。危险的“中止当前回合”放在更多操作中。
- 诊断保留source/epoch/runId/覆盖原因，但不占主层；未知、部分覆盖、较旧或断开仍有可读提示。
- 管理窗跟随系统深浅色，顶部固定深色；动效尊重减少动态效果。无刘海/外接屏用顶部胶囊，camera/safeArea不需要屏幕录制或无障碍授权。
- 原生合成预览脚本 `scripts/create-visual-fixture.mjs` 仅生成明确synthetic记录；`--visual-fixture` 模式不连接真实会话、不保存真实设置、不递送真实管理请求。

## 使用边界

- 追加/纠偏走原生 `sendUserMessage`；该 API 返回 void 时只显示 **requested**，不伪造 queued/accepted。
- 中止当前回合不清空后续队列、不停止独立子任务或外部副作用。Subagents stop 受理与进程终态分开。
- Subagents Fleet key 只展示；后台孩子控制从 owner 的公开定向状态取得真实 runId。resume 由 owner 验证资格，拒绝后不偷开替代任务。
- 计划按 owner 分开。Schedule seam 只复用现有 list/pause/resume/delete 和 event-job trigger，不新增计划库、CRUD 或常驻服务。暂停未来触发不撤销正在执行的工作。
- 侧栏仅会话、Token、重要事项、设置；子任务与计划并入准确会话详情，保留数量、空态、owner/覆盖和未来触发语义。⌘1/⌘2/⌘3、⌘F与下一需关注会话只用本地状态，不发owner轮询。
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
