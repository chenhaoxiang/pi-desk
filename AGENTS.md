# Pi Desk contributor contract

Pi Desk 是 Pi-only 的可视化与管理客户端。先读 `README.md` 与下方 owner 文档；规划、源码、测试、安装、运行和发布分别说明，不能用静态稿或 spec 校验替代实现验收。

## 不变边界

- 不降低现有 AI 自动化：不新增审批、默认模型调用、执行前置、模型/思考档/工具修改，UI 不拥有 Pi 生命周期。
- 默认不扫描历史会话。仅按用户2026-10-26明确授权执行一次canonical Pi JSONL的usage元数据preview/apply/rollback；不保存/输出正文、原路径或凭据，不扩为常驻扫描或历史对话UI。原JSONL只读；其余历史读取仍不在默认范围，不抓终端文本推断成功、不复制profile。
- 观察处理只取必要标量并入有界队列；不等待 socket/网络，不在主路径启动同步子进程，不返回修改输入/输出/continuation 的结果。
- 管理请求通过具体 owner 公共接口；不能提供任意 shell、任意工具执行或内部状态文件修改接口。
- 数据不完整保留 unknown/partial；已受理不等于完成，回合结束不等于任务/CI/部署验收。
- 原生会话、子任务、计划、Token 与治理状态各有 owner，不在本仓复制业务状态库或规则体系。
- 测试使用合成数据与隔离会话。真实环境/账号/安装/部署按当次实际授权；不把规划文档当操作许可。

## 仓库与文件

- 物理主目录只读；tracked 变更在本机约定的专属 worktree，基于已核实默认分支。空仓首次规划没有远端提交基线，须如实说明。
- 默认主分支不直推；只 stage 精确本任务路径。共享交付按适用 PR、审查和验证规则；自审不冒充独审。
- 临时 fixture、日志、截图及生成预览放 `tmp/`，不入业务目录或提交；真实本机路径、会话、管理地址与凭据不写进公开文档。
- `pi-desk-v0-1` 已按本机适用验收归档；现行行为合同在 `openspec/specs/`，历史任务保留于下方归档入口。增量按实际变更决定是否新建 Change，不复制已完成规格；旧快照不能新增审批或冒称 Herdr 正向实机通过。
- 借用 CodeIsland 代码前核对许可、来源与依赖；未复用不得声称已集成。不复制其多工具安装、历史扫描或权限审批层。

## 文档地图

| 需求 | Owner 文件 |
|---|---|
| 产品范围、非目标、用户验收 | `docs/product-v0.1.md` |
| 进程/模块、状态、协议、安全与 Token 语义 | `docs/architecture.md` |
| 公开来源、真实 API、兼容性及接线缺口 | `docs/integration-matrix.md` |
| 顶栏/管理窗口、按钮和异常交互 | `docs/interaction-design.md` |
| 阶段顺序、验证、风险和交付边界 | `docs/implementation-plan.md` |
| 现行行为合同 | `openspec/specs/` |
| 首版归档任务与验收边界 | `openspec/changes/archive/2026-10-30-pi-desk-v0-1/tasks.md` |

正文保留 frontmatter。新增 docs 先查本地图，更新现有 owner 文件；只有入口/职责改变才改地图。四件套只路由，不重复正文。
