# 网关可靠性核查与改进方案（仅分析）

依据用户要求，按[六项外部故障对照](../../evidence/gateway-reliability.md)审计本项目实现和测试，找出原因及验证缺口。依据规范为 P03—P16/P24—P26、E01—E11、U03/U10—U12。本轮不改变业务、协议、健康、用量、持久/schema、客户端配置或部署；下文均为待讨论的改进方案，不表示恢复实施。

## 已有防线与证据边界

- 原生 WS 后续 turn 重新取得当前 Key policy，并经过账号/引用/持久准入；已有真实 socket 测试覆盖禁用 Key/账号、draining 及跨主体拒绝。不是只在握手授权。
- 协调器一次 operation、派发前 intent、预留 finalizer ticket，失败不会自动重放；reader 先观察已关联终态证据，其他 lane 的取消不得抹掉已知用量。
- HTTP 无终态报不确定执行，完整与部分证据独立结算；缺失 usage 保留 unknown。日志 hook 没有控制账本的同类依赖。
- 源码/测试只读对照不等于当前运行验收。本轮本机 arm64 无凭证探针和六项已有定向测试的实际结果见[验证账](verification.md)，没有 Linux、Desktop UI 或真实提供者证据。

## 已确认的行为缺口

### A01：默认协议与实际部署夹具没有共同的客户端验收出口（既有阻塞）

**原因：** `ResponseRequest` 不识别 Lite 工具包，`ClientTools` 仅从顶层建立工具集合；显式 `ModelCatalog` 路径不能覆盖客户端内置默认目录。[此前实验](../parallel-key-trial/verification.md#用户要求先定位不修复后的只读调查)还证明 `trial_provider` 缺少客户端必需的总 token 字段。`verify_client.py` 使用另一个 Provider、固定 synthetic-text 和显式目录，而 `verify_trial_provider.py` 只检查 socket 结果；两个局部检查没有形成同一个客户端闭环。

**缺的验证：** 固定实际客户端版本，默认/显式目录分别经过实际候选与实际夹具，包含预热、工具往返、第二/第三轮和压缩后的下一轮，并核对上游次数、client exit/turn.completed 与账本。不用读取用户历史或凭证。

**建议：** 首选原生 Lite 的有限类型/容量/工具声明/归属支持，保持工具位置和开发者消息顺序；适配上游所需协议标识须单独核实。受信目录只能承诺实际支持能力，显式目录是一条独立受验路径，不静默强制用户改目录。夹具和客户端契约共同维护，不能再用另一套夹具替代。未知工具/对象继续拒绝。

### A02：事件名与 response.status 不一致仍按成功完成（新探针确认）

**位置与原因：** [ProviderObservation](../../../Sources/CodexOneAdapters/Upstream/ProviderObservation.swift)用事件名判断 terminal，而 status 只检查是字符串；[ExecutionObservation](../../../Sources/CodexOneAdapters/Upstream/ExecutionObservation.swift)也按事件名记录结果。没有核对两者是否一致。

**观察：** HTTP SSE、桥接 SSE、原生 WS 中，`response.completed` 携 `status=failed` 都被输出；一次上游调用，账本 settled，outcome.failure 为空。settled 在本项目仅表示用量责任结清，不代表业务成功；这里异常是业务失败分类也为空，以及对外成功事件内部自相矛盾。尚未证明真实提供者会发送这种事件。

**建议：** 先定义有限的事件/状态对应表及允许缺省，再在共同边界检查矛盾；已可信用量不能因错误输出而丢失，但结果应记录协议失败。验证 completed/failed/incomplete 的交叉错配、缺省、未知值和客户端消费，不能把 synthetic fixture 的宽松形状直接变成永久严格规范。

### A03：普通流的逐项输出与最终汇总没有统一一致性检查（新探针确认）

**位置与原因：** `ProviderObservation`逐事件检查对象，HTTP SSE 没有跨事件 response ID 状态；[WebSocketTurns](../../../Sources/CodexOneAdapters/Transport/WebSocketTurns.swift)检查当前 response ID 和已出现 item_id，但不比对普通 output_item.done 与最终 output 窗口。已有 `StreamCompaction` 对压缩具有更强的窗口检查，不能推导普通文本/工具已经等效覆盖。

**观察：** created 的 response A 最终变成 B，HTTP SSE 接受并 settled，桥接/原生 WS 拒绝且 unknown；普通 message 的 done 为 A、终态同一位置变成 B，三路径均接受并 settled。这不是当前真实用户请求已被混流的证明，但确认了同一输入在传输之间的校验差异及多视图不一致可通过。

**影响与缺的验证：** 客户端可能按逐项和最终两种视图保存历史，下一轮出现重复/丢项；涉及工具时可能出现调用身份分歧。本轮只复现 message，未证明客户端会重复执行工具或发生跨用户泄露。现有 compaction 索引/窗口负向测试及 WS 重复终态测试不能替代普通 item 的覆盖。

**建议：** 使用小而有界的执行级关联状态，核对已出现 response ID、item ID/type、output_index、call_id 和完成视图；允许已验证的合法快照差异，不以全字节相等要求 in_progress 与 done 相同。先证明关联属于当前 attempt，再接受对应终态用量；保留此前已确认的可信证据。冲突时停止并明确失败，不能删历史掩盖。覆盖文本、function/custom、reasoning、图片及压缩的区别，不能只验证 helper。

### A04：内部可结算的用量不一定是客户端可消费的用量（新探针及既有原因）

**位置与原因：** `ProviderObservation.usage`校验输入/输出/缓存三个计量字段；`validateUsageContainer`对其他数值主要检查结构，`total_tokens`不参与合法性/一致性校验，终态原样向下游输出。

**观察：** 输入 2、输出 1、缓存 0、total=-1 的终态在三路径均输出 completed 并按已校验字段 complete/settled；不能据此说已知输入输出用量丢失，但下游字段仍矛盾。既有实际内置 CLI 也已证明缺 total 会导致 HTTP 200 后解析失败。本轮负数探针未运行真实客户端。

**建议：** 分开定义提供者计量证据与目标客户端终态 schema；检查必需字段的类型/范围/算术关系。仅在可信完整输入输出已知时，可考虑由明确适配器计算必要总数；缺失证据保持 partial/unavailable/unknown，禁止补零冒充完整。错误用量对外失败与已知计数保留分别验证，避免客户端误重试带来新执行而本地第一次已结算。

## 契约/策略风险与尚未验证项

### A05：错误隐私有保护，但不同失败形状没有共同的分类/消费矩阵

**已确认行为：** `WebSocketTurns`首事件要求 created；合成 `type=error/status=429` 首帧在桥接/原生 WS 被映射为 invalid_upstream_turn，unknown，不透传私密文本。携完整 usage 的 failed 终态若有 error，三路径替换为 upstream_execution_failed；同一 failed 无 error 则转发 response.failed，均保留可信用量并记录 upstream_rejected。

**边界：** 这不是“failed 全部不能处理”或“失败必然漏账”；当前协议也要求原始错误脱敏。待解决的是可支持形状、固定错误类别、客户端处理和账号健康是否一致。首帧示例是合成契约候选，不证明真实订阅必定发送同一结构。

**建议：** 建立首帧拒绝、流中 error、failed/incomplete（含有/无 usage、有/无 error）的矩阵；只映射经确认的状态与固定码，不按任意消息字符串决策，不回显原文。对外失败、账号健康与是否允许重放独立；错误可读不授予重试资格。先用明确版本客户端核对如何结束/重连，再决定保留脱敏 failed 结构还是使用标准 error/关闭。不能伪造限流引导重试。

### A06：所有 HTTP 5xx 都按所选账号/模型冷却，是策略风险而非未实现

[ExecutionObservation](../../../Sources/CodexOneAdapters/Upstream/ExecutionObservation.swift)把 5xx 映射为 upstreamUnavailable，[SQLiteAccountHealth](../../../Sources/CodexOneAdapters/Persistence/SQLiteAccountHealth.swift)默认冷却 15 秒（可受 Retry-After 影响）。现有 `poolHTTPExplicitProviderStatusesPersistHealthAndStopNewDispatchWithoutReplaying` 明确验证 503 冷却，WS 升级拒绝亦覆盖。状态前没有足够来源证据区分共享网关故障和账号特定提供者故障。

**风险：** 连续新请求选择不同账号后，可能把共同网络故障传播成所有账号冷却；本项目不在同一请求中换账号重放，因此与外部项目的放大路径不同。本轮未复现全池耗尽，不能声明线上已经发生；现行为符合现行模型冷却约定，调整须同步策略/规范，不能当小 bug 静默改。

**建议：** 补两账号共享故障与单账号明确拒绝对照，分别保留请求失败、账号健康和共享链路可用性；来源不明的 5xx 不冒充凭证失效。是否引入独立共享链路退让依据样本决定，不照搬外部换账号策略；无新增真实账号探测。

### A07：慢 lane、上传与保活的组合仍缺对抗验证

`WebSocketInbox.push`有每 lane/全局容量及 5 秒期限，reader 等待满 lane 时不能读取后面的其他 lane/控制帧；writer 单次写也有 5 秒关闭路径。按 P04/E08，整连接拥塞关闭是现有明确策略，不属于自动泄漏或无限等待。

已有 `verify_websocket.py` 的 multi-slow 是上游延迟某 lane 的终态，而非某 lane 消费者停止导致 inbox 填满；ping/pong 样本也不是慢上传期间。`verify_long_tasks.py`覆盖总期限/进度/空 delta/保活，容量脚本覆盖长连接，但不能替代该组合。

**建议：** 在有 owner/容量/期限的本地 socket 中施加慢上传、暂停消费、队列满、其他 lane 终态及 ping，并检查 5 秒内关闭、逐 attempt 责任、后续连接容量与资源回稳。先验证已有整连接退让满足产品要求，再决定是否值得引入独立 lane 缓冲/公平调度；不先复制其他项目队列设计。此项未新增运行探针，仍为静态风险/验证缺口。

### A08：逐轮安全覆盖已存在，排队与轮换组合仍未形成客户端闭环

本轮定向测试重新验证池原生连接禁用 Key/账号与 draining；`verify_keys.py`另覆盖同 socket 模型收窄/禁用、HTTP 轮换及已派发后撤销仍结算。`SQLiteAccountRouting`/Key 准入仍有当前策略持久屏障，不能称为已确认权限绕过。

**缺的组合：** 旧 digest 的 socket 保持打开时轮换；请求已经进同 lane 队列后再撤销/缩小模型或耗尽日限额；多 lane 并发修改与下一次持久准入之间的边界。客户端 UI 提示和新会话恢复亦未覆盖。当前 first create 绑定与后续校验不等于这些组合已验收。

**建议：** 用屏障精确定位“已排队、未准入、已准入、已派发”，验证各时点授权与责任；已提交/可能发送后不做绝对即时撤销承诺，未准入的下一轮应拒绝且无新上游调用。

### A09：发布检查没有强制执行代表性的真实客户端检查

`scripts/verify.sh --backend`及 `.github/workflows/verify.yml`不调用 `verify_client.py`；候选 Docker verification 也只跑部分协议/图片/维护脚本。CLI 检查是可选的人工入口，且其固定目录/夹具偏差见 A01。profile 的 clientVersions 是来源披露，并未在 client_version 查询处执行版本匹配，不能当版本兼容门禁；现行规范只用该参数选目录视图，不据此认定授权 bug。

**建议：** 将固定版本、全新私有客户端环境、合成上游的默认路径/部署夹具检查纳入候选出口；主工作流是否运行需考虑可用客户端分发与平台，但未执行必须阻止兼容完成声明。明确支持版本、目录采用/未采用和不支持能力，不靠一条“没有 fallback 警告”穷尽默认行为。Desktop UI 仍单独验收。该流程可发现缺口，不授权订阅生成。

## 推荐的改进顺序与验收

1. **默认客户端完整操作：** A01/A04/A09，先明确 Lite/目录与夹具契约；验收真实客户端文本、工具往返及多轮消费，并同时核对上游次数和账本。
2. **可信流与正确失败：** A02/A03/A05，贯通 HTTP SSE、HTTP→WS、原生 WS 的状态/关联/错误及用量；已确认新缺口适合纳入该闭环，不能按每个字段修完就让用户重试。
3. **授权与故障隔离：** A06/A07/A08，在既有防线下先补对抗样本；依据结果决定健康策略或调度改动，分别说明成本和外部行为。

恢复实施时，先完善对应变更契约/任务，再由主 Agent 实现、定向回归、集中 review 和阶段出口；本轮没有授权这些实现。错误/矛盾终态不能包装成功；已知用量不能丢失；未知执行不退款、不透明重放；跨主体/账号归属始终保留。
