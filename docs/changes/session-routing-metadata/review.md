# 跨项目复盘

2026-11-02，三个独立、无聊天历史的 subagent 只读核对参考项目源码及 GitHub issue/PR；主 agent 另用合成 HTTP/WS 提供者验证。未调用真实订阅，也未把真实反馈内容写入仓库。

## 修复进展

本页保留复盘当时的证据与取舍；运行实现现已修复 token 来源、WS 载体、process seed、刷新后冷却与限流范围，最终证据见[验证](verification.md)。官方 App Server 的 goal RPC 字段未被当作 HTTP 上游契约，不解析辅助正文推断 owner。旧成功清除新过载冷却仍属于待单独讨论的既有语义，本轮未改变。

## 结论与证据边界

此前 398 项 Swift 与 34 个脚本通过，只覆盖原有验收范围。本轮新增探针在 HTTP、WS 两条路径均发现缺口，复盘当时，这些缺口尚未修复。失败探针仅用于本地取证，未混入已有通过的测试结果；测试文件已恢复。复盘取证阶段不修改运行代码，后续实现与验收另行记录。

参考本地 codex-lb 为 2026-08-27 的 6d788664，远端 main 为 72630bbfeee9e3b0d9acfb95e2b1e706b8b0188e（2026-10-16）；不能把本地快照当最新版。CLIProxyAPI 固定 7cad1cb7df48c6c5ffb7ff0b34ef8198806115bc；官方 Codex 固定 ba0d0e1f74ee0f41c27ef24b37ed5fc030b487e7，Magpie 固定 5daba8337be1c5d64cade5bbbe4f3391c451bf8e。下述 issue/PR 状态按复盘日核对。

## 待修复项

1. **P1：将真实续接状态当作可迁移标签。** SessionAffinity 把 turn-state 与 session/thread 放同一 TTL 表；SessionRouting 在回退选择后把全部请求标签改记为新账号。合成提供者从 B 返回状态，禁用 B、启用 A，下一次请求的旧状态仍原样发给 A；HTTP 和 HTTP→WS 均复现。官方客户端在认证 owner 改变时清空本轮状态；参考项目对真实 turn-state 区别处理。建议分离软缓存位置与已观察的续接 owner，后者不可被软回退覆盖；owner 不可选、映射未知或过期时明确处理，不能盲删 token 并重试、也不能移交另一账号。合成结果仅证明转发事实，不证明真实提供者如何拒绝、缓存失效或跨账号访问。
2. **P2：WS 载体转换不完整。** HTTP 客户端回送的 turn-state 仅用于上游握手，未投影到 response.create.client_metadata；只观察 101 头，未观察提供者 metadata 事件的状态，JSON 聚合又丢弃非终态事件。官方当前 WS 从事件取状态，再按消息传入 client_metadata。建议补双向有界转换及“101无头→metadata→completed”JSON/SSE 验收；首输出后不能追加 HTTP 头，不提前建立可能执行的上游以绕开 intent 屏障。
3. **P2：线程与共享 session 的标签更新规则过粗。** 当前每次选择会重写全部标签。T1/T2 共享 session、T2 回退时，会移动仅带 session 的辅助请求偏好。官方父子代理可以共享 session，同时保留不同 thread；两者不应强行一一对应。建议 thread 独立更新，process/session seed 有明确的首次初始化及失效规则；goal 等接口的 threadId 是否参与路由需单独定义有界解析契约，不改写上游正文。映射覆盖是代码事实，辅助状态实际影响仍需线协议验证。
4. **P2：辅助冷却快照跨 await 失效。** ControlExecution 先取剩余秒数，Core 随后可能等待凭证刷新；刷新期间新冷却不会进入旧快照，已到期冷却仍可能被按旧秒数排除。建议凭证准备完成后、紧邻选择时读取单调截止。当前为代码级触发分析，尚未运行并发复现。
5. **契约修正：辅助 429 不能仅凭来源就判定端点级。** 端点自身 5xx 与明确账号 quota exhaustion 应区别处理；本轮统一隔离到端点的设计缺少上游范围证据。明确账号额度耗尽应保留账号保护；模糊错误的保守策略先写入规范再实现，不能用其他项目的开关推导上游保证。

## 后续改进与保留项

- 旧慢请求成功可能清除更新的 overload 冷却。当前规范明确成功清零，所以这是既有并发语义的改进建议，不是此次新引入的契约违例。可借鉴派发序号/健康水位，不需要另建调度器；429 现有删除条件不受此点影响。
- 保留不从 prompt_cache_key 合成会话头、Key 隔离、有界 soft cache、WS 连接固定 owner、强引用授权、持久 intent 和未知执行责任。不引入多副本路由、正文注入、恢复缓存或已派发请求自动重放。
- 先修 P1 与 WS 元数据，再修线程更新/冷却快照及明确限流范围，最后讨论旧成功水位。重新完成合成验收后才考虑 PR 与真实客户端验证；不能用之前通过的测试覆盖本轮发现。

## 近期 issue 与 PR 取舍

- [Codex #44862](https://github.com/openai/codex/pull/44862)：2026-09-11 已合并，父 cache affinity 与独立 thread 身份共存；[官方本轮状态测试](https://github.com/openai/codex/blob/ba0d0e1f74ee0f41c27ef24b37ed5fc030b487e7/codex-rs/core/tests/suite/turn_state.rs)定义 HTTP 与 WS 的状态生命周期。
- [codex-lb #1703](https://github.com/Soju06/codex-lb/pull/1703)：2026-08-15 已合并，process/thread locality 分离；[#1765](https://github.com/Soju06/codex-lb/pull/1765) 2026-08-16 已合并，防止硬 owner 选择覆盖 soft row。
- [codex-lb #1905](https://github.com/Soju06/codex-lb/pull/1905)：2026-10-16 更新，仍 open，不能当作已交付的续接保证；[#2636](https://github.com/Soju06/codex-lb/pull/2636) 2026-10-30 更新、[#2555](https://github.com/Soju06/codex-lb/pull/2555) 2026-10-25 更新，均仍 open，只作失联上下文与收尾场景的参考。
- [CLIProxyAPI #6643](https://github.com/router-for-me/CLIProxyAPI/issues/6643)：2026-10-15 completed；对应 [#6644](https://github.com/router-for-me/CLIProxyAPI/pull/6644) closed 但未合并。当前源码已有不同的执行序号保护，不能把 closed 等同 merged。[WS #2998](https://github.com/router-for-me/CLIProxyAPI/pull/2998) 仍 open；本项目已有连接归属，不能据此引入换号重放。
- [Magpie #3988](https://github.com/yetone/magpie/issues/3988)：2026-10-29 更新，仍 open，讨论自动提示 hash 导致会话碰撞；不照搬其从 body key 覆盖会话头的方案。[当前桥接源码](https://github.com/yetone/magpie/blob/5daba8337be1c5d64cade5bbbe4f3391c451bf8e/internal/gateway/codex_socket.go)可用于理解元数据载体转换，不复制实现。

## 公开讨论补充：透明与托管的边界

同日额外检索维护者答复、官方文档与用户讨论；这些是不同产品目标下的选择，不能据少数 issue 宣称整个社区已有统一共识。

- **主动限制翻译范围。** CLIProxyAPI [#5753](https://github.com/router-for-me/CLIProxyAPI/issues/5753) 的维护者于 2026-09-12 明确拒绝在 passthrough 路径添加 freeform 工具翻译，以 not planned 关闭。透传会保留上游自身的能力缺失，不能承诺让不兼容模型变成完整 Codex 后端；其建议的工具过滤也不等同于我们应默认修改工具声明。
- **透传与治理可以共存，但功能需说明边界。** LiteLLM [透传文档](https://docs.litellm.ai/docs/pass_through/intro)同时保留认证、日志和部分用量能力；[OpenAI WS 文档](https://docs.litellm.ai/docs/pass_through/openai_passthrough)指出原始 WS relay 不读帧、不能校验模型，因此默认关闭，存在模型限制时拒绝该路径。这与本项目需要逐请求授权的目标直接相关，不可用完全 opaque relay 绕开模型/图片能力检查。
- **不替不支持的后端补造会话是明确选择。** LiteLLM [原生 Responses 透传文档](https://docs.litellm.ai/docs/response_api_native_passthrough)让后端自行处理 previous_response_id，不支持时保留错误；托管桥接则另用保存的历史提供能力。其[连续性文档](https://docs.litellm.ai/docs/response_api#load-balancing-with-session-continuity)也要求已知响应回到来源部署，说明透明不免除多部署选择的正确性责任。
- **智能补全会引入身份推断问题。** Magpie [#3988](https://github.com/yetone/magpie/issues/3988) 于 2026-10-28 创建，10-29 的贡献者讨论仍要求先定默认身份语义，未提交修复；它明确标注代码分析而非真实账号复现。不将此转述为已确认的真实缓存事故。
- **透明不能绕过上游限制，错误控制信号也属于协议。** CLIProxyAPI [#4409](https://github.com/router-for-me/CLIProxyAPI/issues/4409) 的贡献者报告直连仍遇到大 WS 消息限制，讨论还指出将 close 1009 转成普通 JSON 错误会影响客户端回退。该 issue 在 2026-08-07 completed；其中自动 SSE 重试建议不能直接采用，本项目仍须遵守可能执行后不重放。
- **能正确透传不等于记账正确。** LiteLLM [#36523](https://github.com/BerriAI/litellm/issues/36523) 报告完整 200 SSE 已到客户端，但误用 Chat Completions 解析器令 Responses 用量记零。当前 issue closed；这里只引用历史缺陷与独立观察的必要性，不断言当前版本仍有该问题。

据此，更适合本项目的候选方向是：同协议透传优先、治理观察与转发分离、必要的协议适配显式化、真实续接不任意换账号、未知语义不自行补造。这里是结合产品目标作出的判断，并非网上投票结论；不要求增加两个用户可见模式，也不提前引入正文恢复或自动重放。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [之前的验证范围](verification.md)
