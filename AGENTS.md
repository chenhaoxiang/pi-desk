# Pi Desk contributor contract

Pi Desk 是 Pi-only 的可视化与管理客户端。先读 `README.md` 与下方 owner 文档；规划、源码、测试、安装、运行和发布分别说明，不能用静态稿或 spec 校验替代实现验收。

## 不变边界

- 不降低现有 AI 自动化：基础观察/管理不新增审批、默认模型调用或执行前置，不改业务Pi模型/思考档/工具，UI不拥有Pi生命周期。用户显式AI分析可选择独立模型，不能成为原工作前置或新状态权威。
- 默认不扫描历史会话。仅按用户2026-10-26明确授权执行一次canonical Pi JSONL的usage元数据preview/apply/rollback；不保存/输出正文、原路径或凭据，不扩为常驻扫描或历史对话UI。原JSONL只读。用户本轮另批准可选AI辅助，并明确选择按需使用所选已接入运行当前分支的有界近期用户/助手文本；只走公开只读SessionManager接口，不读思考/工具原文/凭据文件、不扫描历史目录。提供预览/移除和疑似敏感值阻断，不承诺识别所有敏感内容。其余历史读取不在默认范围，不抓终端文本推断成功、不复制profile。
- 用户已批准同源工作观测：原生成功Todo的结构化任务标题/当前步骤/状态/依赖/owner只作有界白名单内存投影，不读params/description/任意metadata/工具正文，不把completed或owner标签当验收/认证；无公开当前snapshot入口就显示未采集，clear/branch/session变更失效旧投影。
- 观察处理只取必要标量并入有界队列；不等待 socket/网络，不在主路径启动同步子进程，不返回修改输入/输出/continuation 的结果。
- 管理请求通过具体 owner 公共接口；不能提供任意 shell、任意工具执行或内部状态文件修改接口。
- 数据不完整保留 unknown/partial；已受理不等于完成，回合结束不等于任务/CI/部署验收。
- 原生会话、子任务、计划、Token与治理状态各有owner，不复制业务状态库或规则体系。AI优先通过本机已安装Pi的公开SDK ModelRuntime/ModelRegistry按需旁路调用（一次性Node子进程，不创建AgentSession或加载扩展）；缺少本机SDK时仍可使用兼容在线Pi的ModelRegistry。近期文本继续只走所选运行的公开桥接，无工具、不追加业务历史；默认codex-local-8319/gpt-6.1-sol、medium可改，不能静默换模/降档或重发未知结果，数值用量与业务统计分开。
- 测试使用合成数据与隔离会话。用户已明确当前Pi Desk属于测试阶段，后续必要验证后直接覆盖既有唯一安装版，不再同时打开第二个预览App；仍保留正常退出/草稿保护、准确源码与安装回读，不强reload旧业务Pi。其他真实环境/账号/部署按当次实际授权。

## 仓库与文件

- 物理主目录只读；tracked 变更在本机约定的专属 worktree，基于已核实默认分支。空仓首次规划没有远端提交基线，须如实说明。
- 默认主分支不直推；只 stage 精确本任务路径。共享交付按适用 PR、审查和验证规则；自审不冒充独审。
- 临时 fixture、日志、截图及生成预览放 `tmp/`，不入业务目录或提交；真实本机路径、会话、管理地址与凭据不写进公开文档。
- 交互与可选AI基座保留`openspec/changes/pi-desk-assistant/`；当前Pi同源工作台消费Change为`openspec/changes/pi-work-observation/`，分期与治理owner分工见`docs/implementation-plan.md` §0。work_ref/result/handoff/attention语义仍由pi-vista/原生owner维护，不在Desk造第二任务库。
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
