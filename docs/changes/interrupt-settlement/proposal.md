# 中断后断开时续读上游终态

日期：2026-10-31。修改[协议](../../specs/protocol.md)原生 WebSocket 中断与下游断开的最终化规则。

## 问题

前向兼容部署后，用户在 Desktop 停止回复。账本中出现一条 unknown（`client_cancelled`）：客户端发出 `response.interrupt` 后约 1 秒内未收到确认，按 Codex 的 Cancel 规则断开连接，网关随即取消上游，这一轮没有终态与用量。

提供者收到中断后通常很快给出终态和用量。网关在下游已断开时继续读一小段时间，就能把这类 turn 按实际用量结算，不留 unknown。

另外，Desktop 每次请求都发送 `x-codex-beta-features`、`x-codex-window-id`、`x-codex-parent-thread-id`，新日志把它们记为未知头，每个请求多 2—3 行 warning。

## 行为

- 某个在途 turn 已向上游转发过 `response.interrupt` 后，若下游连接关闭，网关不立即取消该 turn 的上游读取，而是继续读取，直到该 turn 终态或 10 秒（不超过原执行期限）为止：
  - 读到终态与可信用量：按现有规则结算；
  - 超时或上游断开：维持现状（unknown，不重放）。
- 续读期间不向下游写任何内容，不接受新请求；连接槽、lane 与预留保持到续读结束后释放；网关停止时续读随运行时取消。
- 未转发过中断的 turn 在下游断开时维持现状（取消，unknown）。
- 上述三个头加入已知允许列表，行为不变（仍转发），不再记未知日志。

## 验收

- 合成上游：中断后下游断开，上游在 10 秒内给出终态 → settled 且用量正确；超过 10 秒或上游断开 → unknown，不重放。
- 未中断时断开：保持现状。
- 续读期间连接资源按时释放；运行时停止时续读被取消。
- 三个头转发且不产生未知日志。
- 执行者完整 `verify.sh --backend` 通过；主 Agent Linux verification；部署后 Desktop 停止回复不再留 unknown。
