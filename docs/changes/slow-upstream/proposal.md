# 慢上传与长时间上游执行

按维护者本任务授权，分别修复 A 图片上传首响应计时、B streaming edits 的完整 JSON 兼容、C 大 Responses 的 HTTP 路由、D 非流式 generations 的上游流聚合、E 慢入站正文及未映射错误诊断。

## 契约与边界

引用 [协议](../../reference/specs/protocol.md)、[执行生命周期](../../reference/specs/execution-lifecycle.md) 与 [用量](../../reference/specs/usage.md)。A 采用既有 UploadBody 的 EOF 边界，不表示远端确认；图片上传块刷新既有进度空闲期限，EOF 切换首响应期限，总执行期限仍覆盖持续慢传；停滞上传取消并保留未知状态。B 只接受受限媒体类型及经验证的完整图片结果，日志仅固定媒体类型 token。C 以最终编码大小预路由，写失败/无事件不能证明未执行，不新增中断重试。D 必须验证完整终态再提交 JSON，保留图片与用量、拒绝截断流。E 通过真实本地 HTTP 慢正文复现后决定修复，不凭生产日志推测原因。

## 验收

只用本地真实 HTTP/WS、fake upstream 与合成正文，覆盖慢传、静默、取消、断连、错误、截断与并发；检查单次派发、账本与响应。按 concern 定向检查，最后一次完整 macOS backend verify，构建 -j 12；不做 Linux/Docker/外部服务验证。

## 迁移与回退

无 schema、版本或凭证迁移。回退恢复旧计时、路由和图片传输行为，慢请求可能再次失败。未知执行责任、持久屏障、禁止重复执行/扣费不变。

## 相关文档

[任务](tasks.md)
