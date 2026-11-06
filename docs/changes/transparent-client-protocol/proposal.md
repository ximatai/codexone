# Codex 客户端协议保真

记录发布后协议审查确认的第一批修复及其验收边界。

## 范围

- HTTP Responses 回传成功上游 HTTP 响应中的单个有效 `openai-model`，由客户端据此识别实际服务模型。目录 ETag、账号级额度和 WS 握手元数据单独验证。
- Responses 错误保留客户端可解析的 `Retry-After`，只提取明确支持的头和值。提供者重试提示与内部健康冷却分别处理。
- 保留 `reasoning` 中未知字段的显式 null。已知兼容字段和内联 ID 继续按现有规则处理。
- 已提交的原生 Images SSE 在失败时使用 Images 的 `error` 事件。HTTP 头提交前沿既有 JSON 错误契约。
- 在兼容说明标明 Realtime 创建路由的范围。普通图片强制 SSE 的收窄需要同账号比较慢响应、断流与用量收尾，另行验证。

## 验收与回退

依据 [P10/P27 和原生图片约定](../../reference/specs/protocol.md)，以合成上游和网关真实 HTTP/SSE/WS socket 验证模型头、错误等待、扩展字段与图片失败。覆盖畸形或重复字段、敏感头隔离、流提交边界及已有执行责任。变更仅在传输和提供者适配器，无数据迁移。回退随运行版本，沿用现有账本、账号路由和执行保护。

## 相关文档

[任务](tasks.md) · [协议兼容](../../reference/compatibility.md)
