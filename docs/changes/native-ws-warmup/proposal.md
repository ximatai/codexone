# 原生 WebSocket 预热的空输出

P14／P15 允许无生成内容的预热生命周期。Rust 将显式 JSON `output: null` 与非空输出数组及畸形类型一同拒绝，Swift 对照允许该空输出形状。Rust 预热应接受省略、null 或空数组三种空输出表示，并保留收到的响应封套。非空输出数组、其他 output 类型及不属于既有例外的非生命周期事件继续拒绝。

在现有私有协议拒绝日志中使用固定原因区分 lifecycle output 与非生命周期事件。名称已知但形状未纳入预热的辅助帧保留现有拒绝，可用固定原因继续核对实际组合。取样沿用现有限速，原因字段由网关常量生成。用量、终态、响应归属、1009 和重放规则沿用原契约。

自然预热失败的观察窗口出现 `warmup_websocket_timing` 分类。初次修正放行数值 `duration_ms`，重新观察仍有该类别的拒绝。固定 Codex CLI v0.170.0 的遥测与上游集成测试使用嵌套 `timing_metrics`。公开观察还出现 `critical_path`，但未提供能确定本部署实际封套的证据。 [上游集成测试](https://github.com/openai/codex/blob/29eb79e9866b3262a777fdf8195c1b9e63684c91/codex-rs/core/tests/suite/client_websockets.rs#L1594-L1644) · [公开观察](https://github.com/openai/codex/issues/56481)

以已支持的原生 WS 预热及已识别的 `responsesapi.websocket_timing` 事件为边界，通过路由、归属及资源校验后转发原封套，包括未知遥测成员及嵌套结构。按已定义的协议位置隔离顶层业务输出、控制、响应/用量等成员。客户端会在通用事件预处理里读取顶层 headers、response.headers 和 safety_buffering，因此 timing 顶层的这些成员也受隔离；不透明遥测树内的同名成员保留。有效的响应标识遵循既有路由约束。 [固定版客户端预处理](https://github.com/openai/codex/blob/29eb79e9866b3262a777fdf8195c1b9e63684c91/codex-rs/codex-api/src/endpoint/responses_websocket.rs#L959-L1005) · [客户端读取位置](https://github.com/openai/codex/blob/29eb79e9866b3262a777fdf8195c1b9e63684c91/codex-rs/codex-api/src/sse/responses.rs#L164-L295)

已支持的协议边界内默认保留遥测数据，转发与采信分别判断。耗时帧仅提供可能已处理的证据，关闭未处理的 1009 例外。它不建立首次响应、有效进展、对象归属、用量或终态，且沿用单事件大小、累计预算和独立期限。回退会恢复 `duration_ms` 的窄许可，沿用原二进制替换和持久化格式，无需迁移。

## 相关文档

[协议规范](../../reference/specs/protocol.md) · [用量规范](../../reference/specs/usage.md) · [验收任务](tasks.md)
