# 客户端协议前向兼容与原生 WebSocket 中断

日期：2026-10-31。修改[协议](../../specs/protocol.md)中原生 WebSocket 控制消息、上游事件转发与客户端头允许规则。用户已同意“默认放行、以结果把关”的方向。

## 问题

测试实例上，Desktop 报错 “Gateway request failed”，网关日志为 400 `unsupported_websocket_control`。Codex 客户端（codex-rs `responses_websocket.rs`）在 Responses Lite 模型上会在同一 WebSocket 发送：

```json
{"type":"response.interrupt","response_id":"<id>","mode":"discard_partial_items"}
```

- 用户取消时发 Cancel：等待 `response.interrupt.accepted` 或 `response.interrupt.failed`，确认可能晚于终态事件到达，客户端截止约 1 秒；
- 处理排队消息或转向时发 Drain：不等确认，继续读到终态。

根因不只是缺这一种消息：网关对不认识的客户端消息一律拒绝、对不属于任何 turn 的上游事件一律丢弃、对允许列表外的 `x-codex-*` 头一律去掉。客户端每新增一种协议，链路就会断。

## 原则

只有会产生新生成、需要计费的请求必须经过网关准入与解析；其他未知内容默认原样转发，以上游结果把关，并留下可观察记录。

## 行为

1. **`response.interrupt`（已知控制）**：
   - `response_id` 属于本连接在途且已收到 `response.created` 的 turn 时，原样写入该连接固定身份的上游 socket；不占准入、不产生执行记录、不改变 lane FIFO。
   - 不属于本连接或已结束时，不写上游，本地在对应 lane 回复 `response.interrupt.failed`（带该 `response_id`），连接保持可用。
2. **未知类型的客户端 WS 消息**：
   - 连接已绑定上游时，原样转发（单条上限沿用现有消息上限，每连接限速，例如每秒 10 条、突发 20 条，超出时本地 400 但不关闭连接）；
   - 尚未绑定上游时（首个 create 之前），仍本地拒绝；
   - `response.create` 继续走现有完整解析与准入。不得把“看起来像 create”的未知类型（含 `input`、`model` 或 `tools` 成员）放行，这类消息本地拒绝。
3. **上游事件**：带 `response_id`（或 `response.id`）且属于本连接最近结束的 turn 的事件，即使在终态之后到达，也转发到对应 lane；不参与用量与终态判定。仍不属于任何已知响应的事件维持现状。
4. **兜底**：上游出现网关未准入的 `response.created`（或其他生命周期起点）时，关闭该连接，并以可审计方式记录一条 unknown 执行（归属当前 Key 与账号），不重放。
5. **客户端头**：`x-codex-` 前缀的请求头整体转发（单值 8 KiB、最多 32 个），认证、账号与门控头仍去除；适用于现有所有使用 `forwardedClientHeaders` 的路径及上游 WS 握手。
6. **可观察**：每次未知 WS 消息放行或拒绝、未知前缀头放行，都记录一条结构化日志：消息类型名或头名、客户端 `version`/UA 类别、结果；不记录内容。
7. HTTP 与 HTTP→WS 桥接：客户端以断开连接取消，不涉及中断消息。

## 验收

- `response.interrupt` 的 Cancel 流程（确认先于、晚于终态）、Drain 流程、未知或已结束 ID、多 lane，账本均按终态结算。
- 未知 WS 消息：绑定后转发、绑定前拒绝、带生成成员时拒绝、超速本地拒绝且连接可用。
- 兜底：合成上游对未知消息返回未准入的 `response.created`，连接关闭并记 unknown。
- `x-codex-*` 新头转发，认证/门控头仍不转发。
- 结构化日志包含类型名、不含内容。
- 单身份与账号池两种配置；完整 `verify.sh --backend` 与 Linux verification 通过；部署后在 Desktop 实际停止一次回复、在回复中途追加一次消息，均不报错。
