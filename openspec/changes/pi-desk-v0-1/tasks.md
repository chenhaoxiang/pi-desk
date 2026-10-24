# Tasks

以下均为**未实施**的后续任务，不把本轮文档/静态稿勾成运行功能。阶段说明见[实施方案](../../../docs/implementation-plan.md)；行为要求只维护在本Change三项spec，具体架构和界面各有owner文档。

## 1. M0 合同与工程骨架

- [ ] 1.1 建立最小SPM App/Core/Transport与TS bridge包，验证Swift build、TS typecheck和公开入口文档，不加入新Pi宿主或daemon。
- [ ] 1.2 冻结wire v1的身份/epoch/seq、能力与动作枚举，建立双端一致的合成fixture，验证半包/非法/超限/未知字段/不匹配主版本负例。
- [ ] 1.3 建立不修改prompt/tools/model/effort/规则与不注册新模型工具的隔离宿主断言，验证bridge关闭和开启基线参数一致。
- [ ] 1.4 配置最小合成测试/泄漏检查及原生build入口，核实实际runner/权限；验证CI不读取真实凭据、不调用模型、不安装全局扩展，记录尚无原生执行器时的缺口。

## 2. M1 在线会话可视化

- [ ] 2.1 实现session_start登记、session_shutdown幂等清理和私有UDS连接，验证无App时Pi照常启动、factory不建资源、无历史/进程扫描。
- [ ] 2.2 实现白名单snapshot/reducer、重连/旧epoch/乱序拒绝与drop标记，验证固定fixture跨语言结果一致。
- [ ] 2.3 实现非阻塞有界生产/消费及退避，验证慢读/断联/满队列情况下原工具不等待、内存有界；记录p95/p99与原轨迹差异。
- [ ] 2.4 实现顶栏与管理窗口的会话列表、详情和准确跳转，验证键盘/VoiceOver/无刘海/外接屏及无效路由不跳错对象，更新交互文档。
- [ ] 2.5 接入agent_settled、原生pending、实际UI等待和owner子任务投影，验证agent_end后续行、自动恢复、多会话及前台/后台孩子不误报完成。
- [ ] 2.6 提供scope明确的接入窗口usage，验证流式只结算一次、部分coverage和重载新窗口；不将M1观察结果标记为完整v0.1交付。

## 3. M2 原生管理闭环

- [ ] 3.1 在有效当前context实现直接Pi follow-up/steer/abort-current路由，验证准确身份/epoch、真实原生队列与既有工具不中断，不伪造durable受理。
- [ ] 3.2 接入Subagents ping/status/steer/stop/resume并按capabilities开放，验证runId与display key分离、归属和恢复资格、当前会话范围，缺owner时原任务继续。
- [ ] 3.3 实现action request/结果/operation-update与有限去重，验证重复点击、丢回复、runtime替换不重复派发，不新建业务账本或盲重放。
- [ ] 3.4 完成两个隔离Pi及一个owned子任务的faux-native管理闭环，验证请求中止/停止受理与实际终态分开、未命中对象继续运行，更新用户操作说明。

## 4. M3 Token与已有计划

- [ ] 4.1 接入可用owner native累计/Subagents cost报告及coverage，验证settled/async完成/用户刷新才有界取数，App不读原会话文件、不周期扫描artifact。
- [ ] 4.2 建立usage黄金fixture，验证input/output/cache、compaction/summary、nested usage、fork继承、父子双卡、未结算和owner下界；无归属不报精确总计，更新统计说明。
- [ ] 4.3 接入Subagents schedule管理allowlist，验证owner命名空间、暂停未来触发不伪称停止当前运行以及不存在/过期目标负例。
- [ ] 4.4 依据当时实际实施授权，在Schedule owner补最小公共在线管理seam与其测试（若仍缺）；验证不越过原session绑定/限额/存储规则，不在Pi Desk直接修改JSON；否则明确未完成的能力边界。
- [ ] 4.5 如果首版确需跨peer精确递送，在Intercom owner补明确mode/wake合同与测试后接入；验证现有v1字段不被当作已有支持，不修改原消息默认行为。

## 5. M4 注意事项与治理入口

- [ ] 5.1 接入实际ui_prompt/question生命周期、提醒已读/静音和准确跳转，验证关闭提醒不代答/取消原问题，generic custom不误归属。
- [ ] 5.2 实现通知来源/稳定事件关联与原兜底，验证接管失败/重复事件不会吞提醒、禁用执行或重跑业务；更新通知说明。
- [ ] 5.3 建立可选治理/Gate/CI安全reader与合成fixture，验证事实/建议/unknown、head/freshness与merge/post-CI分离，未接真实producer明确显示未配置。
- [ ] 5.4 提供用户配置的精确现有管理页入口，验证链接scheme/目标、无任意shell和凭据复制，未配置不影响Pi核心功能；不复制完整控制台。

## 6. M5 完整首版验收与候选打包

- [ ] 6.1 运行实施方案A1–A11组合矩阵，验证相同fixture的新增模型调用/人工确认0、原参数/执行结果不变，记录UI断联/崩溃/背压/更新影响与实际性能。
- [ ] 6.2 核验固定Pi/owner版本及缺少owner/混合版本模式，验证TUI现有能力不因接入被降级，不强reload真实业务会话。
- [ ] 6.3 在已授权的精确隔离本机目标中做原生多会话/输入/跳转/通知验收，区分合成与真实证据，不读取真实历史日志充当fixture。
- [ ] 6.4 构建旁路候选、验证卸载/回退只移除本App与本扩展，记录独立App身份、许可、签名/公证/更新源及尚未执行项；无授权不安装/发布。
- [ ] 6.5 核对所有首版范围、管理能力与证据层级，更新README和产品状态；验证没有把观察里程碑、source通过或静态预览冒称完整首版/已上线。

## Workflow follow-up

- 共享源码交付按当时适用的独立只读审查、PR、检查和普通merge流程；空仓首main的初始化需匹配实际授权，不默认直推。
- 安装、真实启用和发行只按对应范围连续推进，不把本Change的存在当额外批准或操作许可。
- 本Change只在真实实施与适用验收完成后归档；规划产物齐全不等于任务完成。
