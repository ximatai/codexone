# Desktop 辅助控制接口透传

日期：2026-10-30。用户要求功能不得少于旧服务。Codex 客户端除了 Responses、模型目录和 Images，还会在服务商 `base_url` 下调用若干辅助接口。旧服务把它们透传到提供者，本网关目前返回 404，相关 Desktop 功能会失效或静默降级。

## 依据

- Codex 客户端（openai/codex `codex-rs/codex-api/src/endpoint/`）相对服务商 base 调用的接口：
  - `alpha/search`：独立网络搜索。旧服务的推荐客户端配置启用了 `supports_standalone_web_search`，开启后 Desktop 的搜索工具走这里；
  - `memories/trace_summarize`：记忆摘要；
  - `realtime/calls`：语音会话的 SDP 交换；
  - `images/*`：另见 [图片原生透传](../images-native-passthrough/proposal.md)。
- 旧服务（Soju06/codex-lb）还在同一前缀下透传 `thread/goal/{get,set,clear}`、`safety/arc`、`analytics-events/events`、`agent-identities/jwks`（以及 `/backend-api/wham/agent-identities/jwks`）。
  - 透传方式：按会话粘滞选账号，转发到提供者 `/backend-api/codex/<path>`，过滤入站头部后注入账号认证，只请求一次；
  - `realtime/calls` 按隐私策略不记录正文与细节。
- 用户额度、线程用量等 `backend-client` 请求走 `chatgpt_base_url`，默认直连 ChatGPT，不经本网关，不在本变更范围。

## 新契约

1. **路由**：`/backend-api/codex` 下的
   - `POST alpha/search`、`POST memories/trace_summarize`、`POST realtime/calls`、`POST safety/arc`；
   - `GET|POST thread/goal/get`、`POST thread/goal/set`、`POST thread/goal/clear`；
   - `GET agent-identities/jwks`，以及 `GET /backend-api/wham/agent-identities/jwks`。

   都转发到所选账号提供者的同名路径（wham 路径映射到提供者 `/backend-api/wham/...`）。查询串原样保留。其他未列出的路径仍返回 404。
2. **`analytics-events/events`**：本地接受，返回 202 空 JSON，不转发。理由：把客户端遥测以池账号身份上报，会把用户行为归到他人账号名下；Desktop 不依赖它的响应。
3. **认证与路由**：
   - 必须带启用状态的托管 Key；
   - 账号按现有路由选择，优先与该会话的 Responses 执行同一账号（沿用现有亲和提示：turn-state、session、conversation 头）；
   - 单身份配置使用其上游 base；
   - 只请求一次，不切账号重放。
4. **正文与响应**：
   - 请求正文按原字节与 Content-Type 转发，计入全局请求体上限与预算，单请求上限 8 MiB；
   - 响应状态、正文、Content-Type 与安全头原样回传，响应上限 16 MiB，超出时为 502；
   - 提供者错误按 P27 脱敏透传，429 设置账号冷却，401 计入账号健康状态。
   - 头部策略与 Responses 一致：剥离 hop-by-hop 头、客户端认证头和 Cookie，注入账号认证。
5. **计量、容量与审计**：
   - 不创建生成执行 intent，不计入 Key 的请求、token 或费用限额（这些调用不产生生成，计入会让 Desktop 后台行为挤占用户配额）；
   - 由数据服务持有的控制舱壁限流：全局并发最多 8，每个 Key 并发最多 4，不等待，超出时直接返回 429 `control_capacity_exhausted` 并带 Retry-After；许可只释放一次；
   - 只写有界结构化日志：路径类别、Key ID、账号 ID、状态码、耗时；不记录正文、查询串或头部；
   - `realtime/calls` 只记录状态与耗时；
   - 不改 schema。
6. **期限**：总期限 60 秒，`memories/trace_summarize` 为 300 秒；超时返回 504，记为结果未知，不重放。

## 不变项与排除

不实现 realtime WebSocket（`realtime`、`live/*`）媒体通道、`/backend-api/transcribe`、`/backend-api/files`、`/api/codex/usage` 等 `chatgpt_base_url` 路径；不改 schema（如诊断表无法容纳，则只用进程内有界计数并在文档说明）。

## 验收

- 合成上游：
  - 每条路由的方法、路径、查询串、正文字节、Content-Type 和账号头都正确到达；
  - 未列出的路径返回 404，且无上游调用；
  - 无 Key 或 Key 已禁用时在派发前拒绝；舱壁超限返回 429，且无上游调用；
  - 提供者 400/429/500 按 P27 透传，429 设置账号冷却；
  - 超时返回 504 且只有一次上游调用；
  - 超过请求或响应上限的处理正确；
  - `analytics-events` 不转发；
  - realtime 诊断里不出现 SDP 内容。
- 部署后真实验证：在 Desktop 中开启独立搜索，执行一次网络搜索，并核对日志。

## 实现细化

- 总连接 owner 上限为 16，并对普通 HTTP/原生 WS 单独保留 8 连接上限；控制舱壁仍为全局 8/每 Key 4。这样第 9 个辅助请求可进入 HTTP 层返回 429，不会因原 8 连接上限提前断开。所有连接与网络任务仍由数据服务关闭并等待。
- 辅助正文无 8 MiB 免计区：包括小正文在内全部计入 48 MiB 共享预算。压缩请求体沿用 415 拒绝；响应不解压，保留安全 Content-Encoding/Vary。
- 仅启用的托管 Key 可访问（单身份也需 managedKeys）；analytics 本地接收的方法明确为 POST。3xx 状态回传但不跟随重定向；失败状态按 P27。
- HTTP Responses 与辅助请求共用数据服务持有的软头部亲和缓存：按 Key 和标签摘要隔离，最多 1024 条、TTL 一小时；不改变持久对象归属、不跨重启承诺粘滞。已配置模型的账号健康状态用于辅助选择，辅助 429/5xx 作用于全部配置模型。
- 无 schema 变更；结果未知由有界进程日志的 504 表示，不创建执行或恢复账。实现与验证入口见[开发约定](../../development/desktop-control.md)。
