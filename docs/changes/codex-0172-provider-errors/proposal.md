# Codex CLI 0.172.0 提供者错误兼容

回环验收发现两处公开响应会丢失官方客户端的错误分类。首次 SSE 独立 `error` 中的无状态 `server_is_overloaded` 被网关转成 HTTP 502，客户端报告连接失败。无状态的项目开支限额 `error` 被网关转成 HTTP 或 WS 400，客户端归为通用错误。同样的上游错误 code 在 HTTP 503 和 HTTP/WS 429 对照中可正确识别。已有 SSE `response.failed` 也能被客户端识别为过载。[客户端分类](https://github.com/openai/codex/pull/62329) · [客户端流处理](https://github.com/openai/codex/pull/62356)

[P10](../../reference/specs/protocol.md#p10重试超时与外部错误) 和 [P27](../../reference/specs/protocol.md#p27开放协议透传) 将精确匹配的无状态独立 `server_is_overloaded` 错误对外映射为 503，将 `api_key_spend_limit_exceeded`、`project_spend_limit_exceeded` 和 `organization_spend_limit_exceeded` 对外映射为 429。保留提供者 code 与合法 Retry-After。已有显式状态映射、`response.failed` 封套及内部分类沿用现状。无状态过载仍属 `upstream_unavailable`，无状态开支限额仍属 `upstream_rejected`，沿用各自的账号冷却规则。[账号健康规范](../../reference/specs/identity.md)

首事件拒绝须继续通过既有证明门槛才可记完整零用量。过载且缺少可信用量的执行须保留未知责任。保持单次上游派发、续接绑定、Key 本地限额和授权边界。公开状态可能改变客户端重试表现，验收时分别记录应用层重试和网关派发。方案无需 schema 迁移，回退二进制会恢复原错误映射，历史账本照常读取。

## 相关文档

[验收与最小复现](tasks.md)
