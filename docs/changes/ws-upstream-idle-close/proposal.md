# 上游 WebSocket 空闲关闭时同步关闭下游

日期：2026-10-31。修改[协议](../../specs/protocol.md)中原生 WebSocket 的连接寿命规则。

## 问题

测试实例上，Desktop 的一条长连接在两轮之间失去了上游连接：
- 上游 socket 关闭后，网关只把上游侧标记为已关闭，下游连接仍保持打开；
- 客户端下一轮照常发送 `response.create`，网关以 502 `invalid_upstream_turn` 拒绝；
- 客户端显示网络错误，随后重连重试成功。同一时段还出现一次 `execution_indeterminate`。

Codex 客户端会在发送前检查连接是否已关闭（`is_closed`），已关闭时以 `connection_closed` 原因静默重连。直连官方时，服务端关闭空闲连接不会让用户看到报错。

## 行为

- 固定身份的上游 socket 关闭时，如果该下游连接上**没有在途或排队的 turn**，网关以正常关闭帧（1000）关闭下游连接，并释放连接、lane 与预留。
- 适用于任何原因的上游空闲关闭：提供者主动关闭、网络断开、上游连接达到 1 小时寿命。
- 有在途 turn 时，维持现有规则：该 turn 按已有证据最终化（通常为 unknown），不重放、不改道。
- 不在网关侧自动重建上游连接。续接所需的状态由客户端在新连接上处理，与直连官方一致。
- 下游关闭前不再接受新的 `response.create`。如果关闭帧发出前恰好收到新请求，该请求必须在 dispatch 前拒绝，且不产生执行记录或额度占用。

## 回归补充

在本变更中补充测试：请求的 `include` 同时含 `reasoning.encrypted_content` 与 `output.encrypted_content` 时原样转发上游，不在网关拒绝（对应 CodexLB 同类缺陷）。

## 验收

- 合成上游在两轮之间关闭 socket：下游在有界时间内收到关闭帧（1000）；随后新的下游连接可以正常完成下一轮；账本中没有 `invalid_upstream_turn` 拒绝或 unknown 记录。
- 合成上游在 turn 进行中关闭：行为与现在一致（unknown，不重放）。
- 多 lane：一个 lane 空闲、另一个 lane 在途时上游关闭，在途 turn 按现有规则最终化，之后再关闭下游。
- 关闭与新请求竞争：不产生 dispatch。
- 单身份与账号池两种配置均覆盖；HTTP→WS 桥接不受影响。
- `include` 透传回归测试。
- 完整 `verify.sh --backend` 与 Linux verification 通过；部署后观察 Desktop 长连接不再出现该报错。
