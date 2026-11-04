## Why

用户要求Pi Desk成为CEO视角的工作可视化与管理客户端：看清当前工作、Todo、进度、阻塞、下一步与产品任务归属，而非只看在线session/工具名。Pi CLI/Runtime与原生owner是唯一事实及写入来源；Desk不另建任务库、产品事实、调度器或验收权威。Pi治理侧与Desk分工推进，复用已有work_ref/binding/result/handoff/attention合同，不复制治理体系。

## What Changes

- 首批接入当前Pi运行中成功的原生Todo结构化快照白名单，明确当前步骤、原计划状态与依赖；只在既有Snapshot的有界可选字段和内存投影中消费，branch/session/clear边界隔离，未知不当零。本Change不定义新的权威WorkObservation schema。
- 新增工作总览入口，以当前任务、待输入、依赖阻塞和原会话操作为主。Todo完成数只称原计划记录，不推断业务验收；未提供work_ref/产品绑定时明确未绑定，不按cwd或名字猜。
- 沿现有Pi公开管理路径追加要求、打开原会话、查看准确目标；本批不加入任务写入/新调度/自动推理或回答审批。
- 在既有owner文档制定分阶段路线：先原生任务可读，再消费已交付的工作引用/结果/等待合同，最后选一个实际工作项验证无催促续接与交付，逐步实现CEO组合视图。Pi治理合同继续由pi-vista/原生owner维护，Desk不复制治理体系。

## Impact

- Affected specs: 新增pi-work-observation消费规格；现有live-pi-sessions/owned-management/usage-and-attention仍适用。
- Affected code: desk-bridge白名单投影/协议预算，PiDeskCore DTO与只读派生，PiDeskApp工作总览/详情，合成SDK/Swift/UDS与性能回归。
- 不修改Pi治理owner仓、不抢接未交付candidate、不默认扫描历史或强reload。生产/发布/预算/自修改权限不因本规划扩大。
