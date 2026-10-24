# Proposal

## Why

现有Pi自动化已分布在会话、子任务、调度和治理组件中，用户需要统一可视化与管理入口，而不是再维护一套执行体系。首版必须保留原自动推进，只支持Pi、不扫描历史会话，并如实展示Token统计及真正需关注的事项。

## What Changes

- 规划轻量macOS原生客户端和Pi进程内薄扩展，不完整fork CodeIsland。
- 在线会话显式接入、准确身份/能力/状态、原终端与Herdr跳转；不发现旧会话。
- 复用owner原生管理接口完成消息/纠偏/当前回合中止、子任务停止恢复与已有计划管理，不制造新审批、执行器或任务库。
- Token按来源/统计窗口/覆盖展示，父子去重，partial/unknown不伪装完整。
- 待输入、异常、结果未读及治理/CI安全摘要统一入口，保持原通知和执行兜底。
- 对断UI、背压、重复请求、旧runtime与统计失真建立可验收负例。

本Change是**尚未实施的首版行为与方案候选**。本轮只写本地规划，不开始业务实现、改别仓、安装、真实会话接入、推送或发布。写出tasks不代表实施已获授权，后续以最新用户指令为准，不额外建立审批流程。

## Capabilities

### New Capabilities

- `live-pi-sessions`：只接入在线Pi、准确来源与runtime身份、非阻塞观察及自动化不退化。
- `owned-management`：通过原owner公共接口执行有范围的管理，分离受理/执行/终态，防止错误重放或跨对象操作。
- `usage-and-attention`：真实scope的Token与覆盖、父子归属、实际待输入和异常提醒，不扫描历史或制造新工作。

### Modified Capabilities

无。新仓经`openspec list --specs`确认无既有capability，不改上游Pi、Subagents、Intercom、Schedule或外部治理合同。

## Impact

Pi Desk后续新增SwiftUI/AppKit客户端、TS桥接与双端协议fixture。Pi宿主/SDK与各owner均沿既有能力接入；缺少owner seam时分别实施和验证，不在本仓调用私有实现或直接编辑状态文件。

当前影响仅本仓文档和静态合成设计；不触及真实凭据、全局Pi设置、现有会话、模型、业务工作目录或服务部署。完整范围见[产品](../../../docs/product-v0.1.md)，结构见[架构](../../../docs/architecture.md)，阶段见[实施方案](../../../docs/implementation-plan.md)。
