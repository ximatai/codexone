# 协议兼容与恢复边界

说明本地协议契约的覆盖范围，避免把合成成功当作任意上游或客户端的兼容保证。

## 接口范围

Responses 支持 HTTP JSON/SSE、原生 WS 与 HTTP→WS 桥接；模型目录、预热、压缩、客户端函数工具、Images generation/参考图 edits 和部分 Desktop 控制接口各有独立契约。支持 `/v1` 与显式 `/backend-api/codex` 别名，不做任意后缀转发。提供者存储对象、后台生成和通用文件服务不开放。

Realtime 目前仅有创建 POST 的转发。官方客户端完成语音建连所需的 Location 和后续 sideband WebSocket 尚未接入。

普通请求聚合上限 32 MiB，单上游 SSE 事件/WS 帧 8 MiB；图片与辅助控制接口具有独立边界，详见 [P13/P14/P27](specs/protocol.md)。正文大小、模型元数据、错误和未知事件的处理以当前规范为准。

协议扩展默认转发，网关仍约束认证、模型/图片权限、硬引用归属、容量、执行模式及可信用量。字段可转发不代表提供者接受。合成 fixture 为自行编写的事件/状态和生成的纯色图片，不是实际抓包或用户内容。

## 客户端身份与风险

网关会以 Codex 官方客户端的标识与官方 OAuth 客户端 ID 访问上游；非原生客户端按受信配置归一为 Codex 标识。该行为可能违反提供者条款、触发风控或导致账号受限；内部端点和协议可能随时变化。用户须自行确认适用条款与账号授权。provider 名称和工具门控值只是兼容设置，不代表官方授权。

## 恢复语义

续接引用受主体、账号和命名空间约束；不能通过换账号恢复加密推理或私有 ID。已可能发送的生成不透明重放，EOF 不代表终态。下游断开后的有界终态续读用于收尾和用量证据，不保证已有输出可被客户端再次读取。

正文/图片加密恢复缓存仍是设计目标，当前没有可宣称交付的客户端读取闭环。相同正文、请求指纹或工具去重都不能证明重试身份；主动相同的新 turn 仍是新执行。未知用量保留其不确定性，超期关闭不补造零费用。

## 验证范围

仓库提供真实 loopback socket、临时 SQLite、进程重启、固定 CLI 和浏览器合成测试。CLI 结果不能替代 Desktop UI，macOS 不能替代 Linux，单账号路径不能证明多账号路由。发布说明应列具体版本、模型与传输的实际验证范围。

以同一版本的标准 Codex、同一订阅账号的直连行为作对照。已承诺的工作流经网关失败，或结果、续接、重试和调用路径发生实质差异时，先修复再发布。直连也明确拒绝的能力记录提供者限制。未知事件仅有名称告警时继续观察，按其实际影响补充定向回归。优先复用现有测试，分别记录合成传输检查和真实客户端验收。

## 会话与缓存

保留原生客户端的 session/thread 身份：父子代理可以共享 session，同时使用独立 thread；不要求两者一一对应。自定义 Responses 接入由客户端管理稳定身份，不要给所有无关会话配置同一个常量。既有 `prompt_cache_key` 原样转发，网关不会用它合成或覆盖会话头；仅 body 缓存键不构成网关账号偏好。`x-codex-turn-state` 是提供者本轮状态，由客户端在适用的同一轮内回送，不能作为跨会话配置常量。

session/thread 标识只提供账号软偏好；已观察的 turn-state 独立约束来源账号，不能在换号时复用；账号池对未知/过期/丢失的 token 明确返回 503，不自动清除状态重放。强对象/连接归属、授权与健康检查仍优先。账号不可用时可以回退，首请求并发及进程重启不保证粘滞。稳定账号、会话标识与提示前缀有助于复用，但不保证提供者缓存命中率或有效期；工具集、instructions、模型或前缀变化仍需客户端单独排查。HTTP/WS 元数据边界与辅助请求规则见[控制接口约定](control-endpoints.md)。

`prompt_cache_options.ttl` 原样转发。公开 Responses API 在支持的模型上提供 `30m` 和 `12h`，并可返回按 TTL 分组的写入计数。订阅入口须单独核对模型和账号能力，显式配置可能收到提供者的 `invalid_parameter`。用量投影见[协议规范](specs/protocol.md)，公开接口用法见 [OpenAI 提示缓存文档](https://developers.openai.com/api/docs/guides/prompt-caching)。

## 大请求错误的官方客户端源码核查

2026-11-03 只读核查 OpenAI Codex 源码 revision `f9e7b19df8aa75490fc1d90f98d3d95ad716d08e`（不运行客户端、不使用账号）。网关提供明确的 HTTP 413 / WS `status: 413`、`conversation_too_large` 和开始新会话/移除图片提示，不自动重放，也不附重试提示。

该 revision 的 [WS error 映射](https://github.com/openai/codex/blob/f9e7b19df8aa75490fc1d90f98d3d95ad716d08e/codex-rs/codex-api/src/endpoint/responses_websocket.rs) 能读取带 status 的 error 帧并转成 HTTP transport error；只有特定连接期限/previous-response 代码直接要求重试，网关不使用这些代码。[HTTP transport retry](https://github.com/openai/codex/blob/f9e7b19df8aa75490fc1d90f98d3d95ad716d08e/codex-rs/codex-client/src/retry.rs) 只对启用的 429/5xx/传输失败重试，不重试 413。

但是更高层的 [api_bridge](https://github.com/openai/codex/blob/f9e7b19df8aa75490fc1d90f98d3d95ad716d08e/codex-rs/codex-api/src/api_bridge.rs) 将不识别的 413 映射为 `UnexpectedStatus`，[CodexErr.retry_delay](https://github.com/openai/codex/blob/f9e7b19df8aa75490fc1d90f98d3d95ad716d08e/codex-rs/protocol/src/error.rs) 对它仍返回退避重试延迟。因此不能声称此错误可保证该版本官方客户端立即停止 turn 重试；413 的专用网关代码需要客户端识别。保留要求的 413 与诚实大小语义，不伪造模型不存在、认证失败或模型上下文溢出。该结论为固定源码的静态分析，不是 Desktop/CLI 的实际运行验收；其他版本和客户端行为待维护者验证。

## 相关文档

[协议规范](specs/protocol.md) · [客户端协议跟踪](../development/client-protocol-watch.md) · [迁移指南](../guide/migration.md)

## 固定客户端的图片参数核查

发布候选核查了实际 Codex CLI 0.165.0：官方 rust-v0.165.0 对应提交 `360319d8dee62d87e2d59fc0c21805d79519cfed`。其[工具参数与 schema](https://github.com/openai/codex/blob/360319d8dee62d87e2d59fc0c21805d79519cfed/codex-rs/ext/image-generation/src/tool.rs#L94)仅暴露 prompt、transparent_background、referenced_image_paths、num_last_images_to_include；[handler](https://github.com/openai/codex/blob/360319d8dee62d87e2d59fc0c21805d79519cfed/codex-rs/ext/image-generation/src/tool.rs#L504)选择图片模型，未暴露 SVG 作者选择。[底层请求](https://github.com/openai/codex/blob/360319d8dee62d87e2d59fc0c21805d79519cfed/codex-rs/codex-api/src/images.rs#L6)也没有 svg 字段。

核查时官方 main 固定提交 `1e9e8bdb008549fc558ef886791c185c6d3c0814` 的[参数](https://github.com/openai/codex/blob/1e9e8bdb008549fc558ef886791c185c6d3c0814/codex-rs/ext/image-generation/src/tool.rs#L101)新增可条件暴露的 gif，但仍无 SVG 作者选择。因此继续允许普通 SVG 沿图片模型配置，拒绝客户端指定 svg.model；公开 Images API 的可选参数不作为官方智能体客户端已自动使用的证明。此结论限定于所核查的官方 CLI 源码，不覆盖所有闭源客户端。


原生 GIF／SVG 请求成功转发后，提供者仍可能拒绝请求或返回其他格式。对于显式 GIF／SVG，网关检查格式头并将不符的输出作为 502 交付失败处理，同时保留已观察用量。Responses 图片工具也依赖提供者及模型支持。部署前应分别验证文本、原生图片与 Responses 工具；原生图片成功无法证明 Responses 工具可用。
