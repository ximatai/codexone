# 已知上游辅助事件观测

首页协议观测把带响应归属的 response.metadata 和 WebSocket 耗时遥测列为未知事件。将观测使用的名称识别与执行使用的语义分类分开，识别 response.metadata、codex.response.metadata 和 responsesapi.websocket_timing。

执行路径继续使用既有语义分类。连接元数据例外仍检查身份字段，响应归属、进度期限、结算及 1009 重放边界沿用现有规则。观测注册表只保存名称，无数据迁移；回退后这些名称可能再次显示。

参见[协议规范](../../reference/specs/protocol.md)与[客户端协议跟踪](../../development/client-protocol-watch.md)。

## 相关文档

[验收任务](tasks.md)
