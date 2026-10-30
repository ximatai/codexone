# Desktop 辅助控制接口

契约与允许列表见[变更提案](../changes/desktop-control-passthrough/proposal.md)；协议边界见 [P27](../specs/protocol.md#p27开放协议透传)。仅接受启用的托管 Key；单身份也须启用 managedKeys。辅助请求不创建生成 intent，不消费 Key 请求、token、费用配额。

POST `/backend-api/codex/analytics-events/events` 本地返回 202 `{}`。其他允许路由只派发一次，保留原始查询串、正文和 Content-Type；wham 使用提供者同名绝对路径。单身份使用其可信配置的上游 origin，账号池使用经过验证的账号认证；均不继承客户端认证、Cookie、任意内部头或 hop-by-hop 头，不重定向、不重试。

请求硬限制 8 MiB，所有辅助正文（包括小正文）计入数据服务的 48 MiB 共享租约预算；Content-Length 在读取前申请，chunked 增量申请。超限 413，预算不足 503；沿用不接受压缩请求体的边界（415）。响应在提交下游之前有界收集，最多 16 MiB，超出 502。2xx/3xx 状态与正文原样回传（不跟随重定向）；安全响应头允许 Content-Type、Content-Encoding、Vary、Cache-Control、ETag、Last-Modified、Retry-After、x-codex-turn-state，并剥离 Connection 指定的成员。错误按 P27 脱敏处理，不回传任意提供者正文或 Cookie。

传输层最多保留 16 条已接收连接，为饱和控制舱壁返回 HTTP 429 留出余量；普通 HTTP/原生 WS 连接另有限制 8 条，共用总连接 owner 关闭回收。每个数据服务持有控制舱壁：全局 8、每 Key 4，不排队，超限 429 control_capacity_exhausted / Retry-After: 1；许可在成功、错误、超时、取消、断开时幂等释放。正文读取仍受 10 秒连接读取期限约束；辅助派发（含选账号与刷新）总期限 60 秒，memories/trace_summarize 为 300 秒，覆盖首包和完整响应。超时 504 只表示结果未知；关闭并等待本地上游任务，不证明提供者停止执行，不重放。

账号池应用用例复用生成路径的凭证准备/刷新，存储端口复核 Key 版本、账号状态、凭证版本和有效期，按亲和优先、活跃生成数、账号 ID 排序；不执行生成准入或额度预留。辅助端点的 429/5xx 冷却作用于全部配置模型，401 标记当前凭证版本认证失败，与后续 Responses 共用健康状态；凭证版本变化后迟到观察不影响新凭证。

服务拥有最多 1024 条、一小时 TTL 的软亲和标签，按 Key 和头名对标签做 SHA-256 后存储，仅影响路由偏好、不授予归属。标签为 x-codex-turn-state、session_id、x-session-id、conversation_id、x-conversation-id；HTTP Responses 记录所选账号及提供者返回的 turn-state，辅助请求优先使用同标签最近账号。标签缺失/过期/账号不可用时按当前健康池选择；不承诺跨重启粘滞，原生 WS 仍遵循其固定身份契约。

结构化控制日志每进程最多 16 条/60 秒，只含固定路径类别、Key ID、账号 ID、状态和耗时；realtime/calls 只记录状态与耗时。超时日志的 504 是进程内结果未知证据，不产生持久执行/恢复责任或 schema 变更。诊断限额可能抑制单次日志，不能作为完整审计账本。

合成验证：`python3 scripts/verify_control.py --binary .build/debug/codexone`（包含真实 60 秒期限）；账号池 OAuth、亲和、无 intent 与冷却联动由 Swift `poolControl*` 端到端测试覆盖。入口注册在 `verify.sh --backend`。真实提供者路由的可用性、错误形状与 Desktop 体验仍须部署后使用授权账号验收；本地合成证据不能替代它。
