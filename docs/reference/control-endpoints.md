# Desktop 辅助控制接口

列出 Desktop 辅助控制接口与认证、转发和容量边界。

允许列表见下表；协议边界见 [P27](specs/protocol.md#p27开放协议透传)。仅接受启用的托管 Key；单身份也须启用 managedKeys。辅助请求不创建生成 intent，不消费 Key 请求、token、费用配额。

## 允许路由

| 方法 | 路径 |
|---|---|
| POST | `/backend-api/codex/alpha/search`、`memories/trace_summarize`、`realtime/calls`、`safety/arc`（后三项同前缀） |
| GET / POST | `/backend-api/codex/thread/goal/get` |
| POST | `/backend-api/codex/thread/goal/set`、`/backend-api/codex/thread/goal/clear` |
| GET | `/backend-api/codex/agent-identities/jwks`、`/backend-api/wham/agent-identities/jwks` |
| POST | `/backend-api/codex/analytics-events/events`（本地 202） |

未列路径返回 404，不派发上游。

## 转发与资源边界

POST `/backend-api/codex/analytics-events/events` 本地返回 202 `{}`。其他允许路由只派发一次，保留原始查询串、正文和 Content-Type；wham 使用提供者同名绝对路径。单身份使用其可信配置的上游 origin，账号池使用经过验证的账号认证；均不继承客户端认证、Cookie、任意内部头或 hop-by-hop 头，不重定向，仅发送前连接建立可在原期限内重试；发送后不重放。

请求硬限制 8 MiB，所有辅助正文（包括小正文）计入数据服务的 48 MiB 共享租约预算；Content-Length 在读取前申请，chunked 增量申请。超限 413，预算不足 503；沿用不接受压缩请求体的边界（415）。响应在提交下游之前有界收集，最多 16 MiB，超出 502。2xx/3xx 状态与正文原样回传（不跟随重定向）；安全响应头允许 Content-Type、Content-Encoding、Vary、Cache-Control、ETag、Last-Modified、Retry-After、x-codex-turn-state，并剥离 Connection 指定的成员。错误按 P27 脱敏处理，不回传任意提供者正文或 Cookie。

传输层最多保留 `dataConnections + 16` 条已接收连接，为饱和控制舱壁返回 HTTP 429 留出固定16条余量；普通 HTTP/原生 WS 连接限制为 `dataConnections`（默认128，8—1024），共用总连接 owner 关闭回收。每个数据服务持有控制舱壁：全局 8、每 Key 4，不排队，超限 429 control_capacity_exhausted / Retry-After: 1；许可在成功、错误、超时、取消、断开时幂等释放。正文读取与数据入口共用 10 秒无进度、120 秒总读取期限；可写连接在正文超时返回 408 JSON 后关闭；辅助派发（含选账号与刷新）总期限 60 秒，memories/trace_summarize 为 300 秒，覆盖首包和完整响应。超时 504 只表示结果未知；关闭并等待本地上游任务，不证明提供者停止执行，不重放。

账号池应用用例复用生成路径的凭证准备/刷新，实际选择时复核 Key revision、启用/到期、账号状态与凭证有效期；按亲和、活跃生成数、账号 ID 排序，不创建生成 intent。辅助 5xx 仅冷却同账号/端点（服务内最多 1024 项、最长一小时）；429 不猜测为端点级，保留账号级配额保护，401 保留当前凭证认证屏障。凭证准备完成后在存储选择点读取最新单调截止；纯冷却导致无候选时返回 503 与适用 Retry-After。凭证版本变化后的迟到账号级结果不影响新凭证，派发不重试。

软位置与续接来源由数据服务分别维护，均按 Key 隔离、保存摘要，分别最多 1024 项、一小时单调 TTL；续接来源在成功查找时刷新期限与淘汰顺序，未命中与冲突墓碑不刷新。soft 标签包括 thread-id、session-id 及既有旧头；thread 可更新自身位置，process/session seed 只首次初始化，不被兄弟线程回退覆盖。辅助请求不更新这些标签。来源状态只观察提供者返回的有界 turn-state；跨账号出现同值标记不可用，不把请求携带的 token 重新归属给所选账号。

已知 turn-state 约束候选账号，但不授予对象授权或 draining 资格；未知/过期/淘汰/重启丢失/冲突 token 在账号池返回 503 continuation_owner_unavailable，来源账号不可用或与强对象/固定连接冲突时拒绝，不换号、不删 token 重放。可信 single 部署可以原样转发未知有效 token；池内临时只剩一个账号不构成此例外。辅助端点冷却也不能使带状态请求换账号。软历史/会话偏好才可按既有健康规则回退。

HTTP JSON/SSE 回传首输出前观察的有界非逐跳 x-codex-turn-state。HTTP→WS 把本次请求明确状态转入 client_metadata；原生 WS 仅首条 create 可兼容握手状态，后续消息只用自身字段，载体冲突/重复/畸形状态在 intent 前拒绝。上游 response.metadata / codex.response.metadata 事件接受字符串或非空数组首元素中的有效字符串，沿用有界校验，其他形状忽略；每个有效状态均记录来源，包括 WS 轮次外转发的事件，只有每个执行首个有效事件状态可用于返回头；普通事件内容继续透传，JSON 聚合只返回终态。SSE 已提交头后不能补头；原生 WS 已升级不能追加 HTTP 头。不提前上游连接、不注入跨轮缓存状态。thread/goal 等辅助 body 原样转发；官方 App Server JSON-RPC 字段不构成这些 HTTP 端点的路由契约，不据此推断 owner。

状态头先在原始载体上验证，重复、超长或声明为逐跳成员的状态返回 400，不能由转发过滤变成无状态请求；有效状态优先占用既有 32 个 x-codex 头中的一席。WS 握手状态无效时拒绝升级；首条 create 的状态畸形或与握手冲突时，记录拒绝并尽力发送带 status 的标准 error 帧，不建立上游或创建 intent。HTTP SSE 与 WS 共用 metadata 状态提取规则；SSE 头已提交仍记录事件状态来源，供后续明确续接使用。

结构化控制日志每进程最多 16 条/60 秒，只含固定路径类别、Key ID、账号 ID、状态和耗时；realtime/calls 只记录状态与耗时。超时日志的 504 是进程内结果未知证据，不产生持久执行/恢复责任或 schema 变更。诊断限额可能抑制单次日志，不能作为完整审计账本。

合成验证：`python3 scripts/verify_control.py --binary .build/debug/codexone`（包含真实 60 秒期限）；账号池 OAuth、亲和、无 intent 与冷却联动由 Swift `poolControl*` 端到端测试覆盖。入口注册在 `verify.sh --backend`。真实提供者路由的可用性、错误形状与 Desktop 体验仍须部署后使用授权账号验收；本地合成证据不能替代它。

## 相关文档

[文档导航](../README.md)
