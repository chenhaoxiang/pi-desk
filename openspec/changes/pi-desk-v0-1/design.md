# Design

## Context

动机与capability见[proposal](proposal.md)。初始仓为空仓规划，现已实现本机稳定候选并继续时间统计增量；用户已确定Pi-only、默认无历史扫描、Token统计和自动化不退化；2026-10-26另授权一次canonical Pi usage元数据补采。主要源码事实与固定基线见[接口矩阵](../../../docs/integration-matrix.md)，不把源码存在当作已安装兼容。

## Goals / Non-Goals

**Goals:** 本机原生轻量客户端连接已运行Pi；观察与管理分离；复用原生身份、owner动作和统计；UI退出或失效不成为主执行依赖。

**Non-Goals:** 新Agent宿主/daemon/任务库/调度器/审批者、其他AI工具、历史对话导入/常驻扫描、强制TUI迁移、任意shell代理、远程协议、手机硬件伴侣、真实环境接入及发行。

## Decisions

1. **独立小客户端，不完整fork。** 选择SwiftUI/AppKit、SPM和TS宿主扩展；只在确定收益与MIT归属后局部借用CodeIsland。替代方案是全fork关开关，但多工具配置/Discovery/审批/大AppState仍带来维护与行为风险。
2. **只连接既有宿主。** 扩展从session_start登记，session_shutdown幂等清理。没有App仍运行原Pi，不由App启动/持有RPC子进程。替代方案是统一裸SDK/RPC，会改变资源加载、TUI自定义交互和生命周期，不满足非退化。
3. **本机UDS与封闭记录。** 每个连接有nativeSessionId/epoch/seq；后台读取、白名单投影和有界队列。不开网络端口或服务端，不新增持久业务库；本轮明确需求新增usage-only异步spool与本机SQLite唯一索引，只记录final标量和coverage，App关闭后仍可采集。详细预算、peer校验和协议表见[架构§4–5](../../../docs/architecture.md)。
4. **管理能力由owner宣布。** 直接Pi消息/abort-current与Subagents RPC复用原接口；缺少Schedule/Intercom seam就补在对应owner或明确不支持，不能从旧字段猜语义。相同动作由GUI和原工具并列调用，不增加授权规则。
5. **传输成功不是执行完成。** 同epoch短期去重只防重复调用，未知回复/新epoch后不自动重发；保留owner操作引用并对账，不承诺外部副作用exactly-once。
6. **统计范围先于数字。** TUI没有ctx.getSessionStats，默认接入窗口；可用时显示owner原生累计/cost。父子不重复、未覆盖为partial、零不替代未知。原owner读当前关联产物不等于Pi Desk广泛历史扫描。
7. **提醒不驱动执行。** 实际输入生命周期与规则/CI摘要分来源，静音/已读不触发continue或回答问题；不加LLM judge或后台模型轮询，保留原通知兜底。

长期结构唯一维护在[系统架构](../../../docs/architecture.md)，交互唯一维护在[交互设计](../../../docs/interaction-design.md)，本页不复制完整协议与页面设计。

## Risks / Trade-offs

- [扩展与Pi共享事件循环] → callback仅取有界标量，网络/统计异步；性能负例失败先修接线，不减模型能力过线。
- [IPC掉线、旧epoch或丢回复] → 只读当前快照、拒绝旧对象动作、owner引用对账，不业务重放。
- [同UID控制端并非强隔离] → owner规则保留、明确本机合作用户威胁模型，不宣称安全沙箱。
- [Subagents或其他owner不存在/混合版本] → capability定向降级，仅对应按钮不可用，原任务/工具不受影响。
- [Token scope与父子成本重叠] → 黄金fixture、coverage与来源；无明确归属就不报精确总计。
- [治理/服务producer尚未接通] → 可选reader与原管理页，未配置明确显示；不读取私有raw日志充数。
- [新仓无远端main首提交] → 本地worktree保全方案，不为了PR擅自直推main或改变仓库规则。

## Migration Plan

本轮包含一次显式usage-only索引迁移，原JSONL只读；SQLite备份/事务/精确回退保持后续实时数据。M0–M5实施和验证现状，见[实施方案](../../../docs/implementation-plan.md)及[tasks](tasks.md)。先隔离faux-native，再按授权小范围真实接入；不强reload忙碌会话。

回退退出App并按原加载方式移除本扩展，保留原Pi/owner配置与会话。签名、公证、更新源、安装、启用和发布分别验证，不从代码/静态稿推断。

## Open Questions

仅剩可后置发行事项：正式版本号、分发许可和更新渠道。它们不改变首版行为/架构/任务拆分，也不是本轮规划前置。管理上下文、usage准确性与背压不是搁置问题，均已列入最早实施与负例验收。
