# 上游 WebSocket 正文上限

定义超限请求的传输选择、确定性错误及回退边界。

## 目标与依据

维护者已观察大图片请求在约 16 MiB 边界失败；16,777,216 字节是依据边界推断的提供者消息载荷上限，并非已确认的 close code 或稳定提供者承诺，可随提供者变化调整。无需重新采集真实上游证据。

遵循 [P06/P08/P10/P27/P28](../../reference/specs/protocol.md)、[E01/E06/E11](../../reference/specs/execution-lifecycle.md) 与 [U13](../../reference/specs/usage.md)：在 dispatch 前按实际有序编码后的 response.create UTF-8 载荷判断，超过限制不发送 WS。HTTP 独立请求可按原账号路由、会话头与现有 HTTP 用例回退一轮；后续仍选择 WS。原生 WS（包括无 previous_response_id 的增量输入）、warmup、连接状态不假定 HTTP 等价，超限明确拒绝。HTTP 桥接超限且含 previous_response_id 时明确 413；低于上限沿用既有校验，不能删字段换取回退。

## 验收

本地真实 binary + 合成 fake provider 强制 16 MiB/1009，覆盖边界、JSON/SSE/native、续接、HTTP 成功/413、取消、账本/账号健康与键序字节。原有 32 MiB 本地正文限制及其他关闭行为保持。日志仅有有界大小桶和路径，无正文。

## 迁移与回退

无 schema、配置或版本变更。回退后大请求可能再次进入 WS 并留下未知执行责任；不能重放此前未知请求。真实上游是否接受上述大小、HTTP 是否接受大请求及真实客户端组合，均待发布后由维护者验收；合成成功不代表提供者兼容。

## 相关文档

[协议规范](../../reference/specs/protocol.md) · [贡献指南](../../../CONTRIBUTING.md)
