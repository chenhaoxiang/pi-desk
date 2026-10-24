# Pi Desk

**看清 Pi 的运行，管理正在进行的工作，不打断自动化。**

Pi Desk 是规划中的 Pi 专用轻量 macOS 原生可视化与管理客户端。它连接已经运行的 Pi 会话及其现有管理能力，不是另一个 Agent 宿主、终端、调度器或审批中心。

## 当前状态

2026-10-24：产品范围已收敛，仓库处于**本地架构与实施方案候选**阶段。尚无业务实现、可安装应用、已验证的运行时兼容性或发布承诺；文档和静态交互稿不代表功能可用。

## 首版范围

- 已接入的在线 Pi 会话、父子任务、模型、工具与状态总览，跳转到原终端/Herdr。
- 复用原 owner 能力发送要求、纠偏、中止当前回合、停止或恢复子任务、管理已有计划；动作按实际能力开放。
- Pi Token 使用统计，明确数据来源、统计范围、父子覆盖及未知状态，不重复计数。
- 重要异常、实际待输入事项、治理/交付状态与现有服务管理入口。

不支持其他 AI 工具，不扫描/导入历史会话，不重复保存聊天和凭据，不新建任务库、执行器、自动审批或模型判断层。手机/手表/硬件桌宠、独立 SSH 与复杂外观定制不在首版。

## 不退化原则

原来自动推进的继续自动推进；关闭或更新 Pi Desk 不停止 Pi。观察发送不等待界面，不增加模型调用、人工批准或默认工具。管理请求复用原接口，不绕过原规则；请求受理、实际执行和结果验证分别显示。

## 从哪里开始

- [产品范围与验收](docs/product-v0.1.md)
- [系统架构](docs/architecture.md)
- [已核实接口与缺口](docs/integration-matrix.md)
- [交互设计](docs/interaction-design.md)及[静态合成预览](docs/design/pi-desk-v0.1.html)
- [分阶段实施方案](docs/implementation-plan.md)
- [首版行为合同与任务](openspec/changes/pi-desk-v0-1/proposal.md)

原生实现拟使用 SwiftUI/AppKit 与 Swift Package Manager；Pi 薄扩展使用 TypeScript 与宿主公共 API。具体目录见架构文档，目前没有这些运行时代码。

## CodeIsland 的关系

本项目是独立新仓，不是 CodeIsland 的完整 fork。只研究有明确收益且能隔离依赖的交互实现；首版不整库复制。若后续复用 MIT 代码，必须记录来源/精确版本及保留许可，并分别核查依赖和素材授权。本轮未复制 CodeIsland 源码、图标、动画或品牌素材。

## 本地规划检查

需要官方全局 OpenSpec CLI，不把私有工作区工具作为公开仓的运行依赖：

```sh
openspec doctor --json
openspec validate pi-desk-v0-1 --strict --no-interactive
```

后续实现的构建、测试和安装说明在对应阶段验证后补充；不提供尚不存在的运行命令。
