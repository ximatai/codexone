# 提供者错误兼容验收

记录固定客户端的合成回环复现和后续验收范围。

- [x] 在 macOS arm64 使用基线 `53265c9` 和 GitHub Release 的 Codex CLI 0.172.0，核对发行包 SHA-256，以合成回环响应复现。关闭客户端请求及流重试，每条失败生成均只派发一次。
- [x] 复审通过。仅调整独立无状态错误对外状态，沿用首事件证明门槛、账号冷却及终态内部分类。
- [x] 实现映射并同步协议规范。用 HTTP 提交前、已开始 SSE 和原生 WS 的代表用例复核 CLI 分类、Retry-After、派发及账本。

## 基线最小复现

用一次不含工具的 CLI 生成请求通过网关访问本地合成提供者。HTTP 上游返回 200 SSE 并发送以下首事件，保持连接短暂开启。

```json
{"type":"error","error":{"code":"server_is_overloaded","message":"Synthetic capacity error."},"headers":{"Retry-After":"2"}}
```

网关下发 HTTP 502，保留原 code 和 `Retry-After: 2`。CLI 报告 `httpConnectionFailed`，账本为 `unknown/upstream_unavailable`。若先发送有效的 `response.created`，网关下发 `response.failed`，内层保留 code 和提示，CLI 报告 `serverOverloaded`。若提供者直接发送带响应 ID 的 `response.failed`，原样的终态也触发 `serverOverloaded`，账本为 `unknown/upstream_rejected`。提供者直接返回 HTTP 503 并保留同一 code 和 Retry-After 时，CLI 同样显示 `serverOverloaded`。畸形 Retry-After 在已开始 SSE 对照中被移除。

将提供者首事件换为以下负载。原生 WS 用同一个 JSON 作为文本消息。

```json
{"type":"error","error":{"type":"insufficient_quota","code":"project_spend_limit_exceeded"}}
```

基线 HTTP 和原生 WS 分别下发 HTTP 400 和带 400 的错误帧。CLI 报告 `other`，账本为明确拒绝并结算零用量。提供者带 HTTP/WS 429 的对照保留相同 code，CLI 报告 `projectSpendLimitExceeded`，账本为 `settled/rate_limited`、完整零用量。WS CLI 可能另有一次独立成功的预热。

## 实现后验证

2026-11-26 在 macOS arm64 使用 Rust 1.96.0 构建真实网关，以固定 Codex CLI 0.172.0 和合成提供者复验。无状态过载在 HTTP 提交前返回 503 并识别为 `serverOverloaded`。已开始的 SSE 仍返回 `response.failed`；无可信用量时均保留未知账本。无状态项目限额在 HTTP 和原生 WS 返回 429 并识别为 `projectSpendLimitExceeded`，内部仍为 `upstream_rejected`。有 `insufficient_quota` 证明的首事件结算为完整零用量，只有作用域 code 的案例仍为未知。有效 Retry-After 随原 code 保留，畸形值丢弃。每次失败生成只派发一次，WS 预热单独结算。

Responses 契约测试覆盖三个作用域、显式状态、冷却和首事件证据，对照用例通过。HTTP/WS 提供者事件透传回归通过。本次验收使用合成回环，Windows Desktop 和生产链路尚未验收。

## 相关文档

[兼容提案](proposal.md) · [贡献指南](../../../CONTRIBUTING.md)
