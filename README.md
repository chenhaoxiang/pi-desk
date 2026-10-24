# Pi Desk

**看清 Pi 的运行，管理正在进行的工作，不打断自动化。**

Pi Desk 是 Pi-only 的轻量 macOS 原生可视化与管理客户端。它连接已经运行的 Pi 会话，不是另一个 Agent 宿主、终端、调度器或审批中心。

## 当前状态

2026-10-24：已有 **SwiftUI/AppKit + TypeScript 本地源码候选**，不再只是静态稿。原生窗口、顶栏、双向私有 UDS、在线投影、原生消息/中止、Subagents 管理与统计、现有计划及注意事项均有实现；隔离真实 SDK、真实 Subagents owner 和 Schedule 管理 seam 候选的 faux-provider 验证见[实施记录](docs/implementation-plan.md#6-本地实施与证据层级)。

这**不是已发行的完整 v0.1**：Herdr 实机跳转、系统通知交付/无障碍完整组合及长期真实 TUI 验收尚未完成；Gate/CI 无真实 producer。未全局安装扩展、未重载业务会话、未发布或部署。远端仍为空，本地候选不代表共享 main 或 GitHub CI 已通过。

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

原生检查使用 Foundation 可执行检查 runner，因此只装 CommandLineTools 时也可运行，不要求额外安装 XCTest。旁路候选位于 `tmp/candidate/Pi Desk.app`，只做 ad-hoc 本机签名，无公证、自动更新或安装步骤。

真实 owner 组合检查是显式选择的本地测试，不读取业务会话：设置 `PI_DESK_SDK` 为已审核 SDK 包根、`PI_DESK_SUBAGENTS` 为已审核 Subagents 包根、`PI_DESK_SCHEDULE_PROMPT` 为带管理 seam 的 Schedule 源码候选根，再运行 `scripts/check-subagents-native.mjs` 或 `scripts/check-schedule-native.mjs`。这些检查创建自己的合成会话、faux provider 和临时产物；不能用缺少 seam 的已安装 Schedule 版本冒充候选。

## 显式接入（仅在你选择的隔离会话中）

先手动打开本地候选，再从本仓显式加载扩展：

```sh
PI_DESK_PEER_CHECK="$PWD/tmp/candidate/Pi Desk.app/Contents/Helpers/PiDeskPeerCheck" \
  pi --extension ./packages/desk-bridge/src/index.ts
```

默认 socket 在当前用户的 `Library/Caches/PiDesk/runtime/desk.sock`；可通过 `PI_DESK_SOCKET` 和 App 的 `--socket-path` 指定相同的隔离路径。App 的 `--settings-path` 可将本 App 设置放到独立测试目录。桥接不会自动安装、启动 Pi、选择模型、修改思考档或增加工具。

`PiDeskPeerCheck` 是随 App 打包的有限 UID 检查助手：Node 通过公开的子进程 stdio API 传入已经连接的 fd，助手只执行 `getpeereid(3)` 后退出。没有另一个 Agent、守护进程或网络服务。缺少助手、UID 不符或路径不安全时，只有观察连接不可用，原 Pi 继续运行。

## 使用边界

- 追加/纠偏走原生 `sendUserMessage`；该 API 返回 void 时只显示 **requested**，不伪造 queued/accepted。
- 中止当前回合不清空后续队列、不停止独立子任务或外部副作用。Subagents stop 受理与进程终态分开。
- Subagents Fleet key 只展示；后台孩子控制从 owner 的公开定向状态取得真实 runId。resume 由 owner 验证资格，拒绝后不偷开替代任务。
- 计划按 owner 分开。Schedule seam 只复用现有 list/pause/resume/delete 和 event-job trigger，不新增计划库、CRUD 或常驻服务。暂停未来触发不撤销正在执行的工作。
- Token 是接入窗口或 owner 当前会话报告，不是每日/账户账单；缺失为 unknown，附加消耗/归属不全为 partial，不把父子报告或不同窗口重复相加。
- 提醒已读/静音只改表现，不回答问题、不阻断执行。原 producer 通知从不被本客户端静默抑制。
- Herdr 跳转只在精确当前会话文件与实时 owner 快照匹配时开放；未配置或失败不打开同名对象。管理页仅允许用户配置的无凭据、无 query/fragment 的精确 HTTPS 地址。
- 关闭、断联或结束 Pi Desk 不结束 Pi；不扫描历史 JSONL、终端文本、旧会话或凭据。

## 文档和规格

- [产品范围与验收](docs/product-v0.1.md)
- [架构、协议及统计语义](docs/architecture.md)
- [接口与实际接线](docs/integration-matrix.md)
- [交互及原生检查范围](docs/interaction-design.md)，[原始静态设计稿](docs/design/pi-desk-v0.1.html)
- [实施记录、验证与未完成项](docs/implementation-plan.md)
- [单一 Change 与任务](openspec/changes/pi-desk-v0-1/tasks.md)

规划合同可用官方全局 CLI 检查：`openspec validate pi-desk-v0-1 --strict --no-interactive`。文档/spec 通过不是业务验收。

## 与 CodeIsland 的关系

这是独立新仓，不是完整 fork；当前外壳和适配是本仓实现，**没有复制 CodeIsland 源码、图标、动画或品牌素材**。没有继承其签名、公证、发行或更新身份。依赖 Pi 与各 owner 的公共接口，不重新分发另一套 Pi 宿主。
