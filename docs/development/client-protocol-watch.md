# 客户端协议跟踪

在升级客户端或网关前发现新增字段、事件和工具门控变化。

## 检查方法

网关对未知 WS 控制与 `x-codex-*` 头记录有界的 `Client protocol extension` 分类日志，不记录内容；管理台首页展示协议扩展提醒。观察到新名称时用合成 fixture 检查转发、授权和用量边界。

手动固定 OpenAI Codex revision 后比对 `codex-rs/codex-api/src/`（含 `images.rs`）、`codex-rs/ext/image-generation/`、`codex-rs/core/src/client.rs`、`codex-rs/core/src/session/turn.rs`、`codex-rs/protocol/src/openai_models.rs`、`codex-rs/features/src/lib.rs` 与 `codex-rs/core/src/tools/spec_plan.rs`。目录迁移时先重新定位，不能因旧路径无差异就断定无变化。重点核对 WS 控制、Responses 字段/事件、Images 请求与工具严格参数、include、模型元数据与工具注册。

已进入 Responses HTTP/SSE/WS 执行消费路径的未知上游事件，只将通过名称校验的 `upstream_event.<type>` 记录到现有进程级注册表；与客户端扩展共享 32 个名称容量、128 字节名称上限及 overflow 信号。超长名称归为固定 long_name；不保存值、正文或任意 JSON，不新增日志原文。reader 在归属检查前隔离的事件不承诺出现在该观察中。观察用于发现和人工复核，不自动授权、续期或结清。

名称识别与执行语义独立。response.metadata、codex.response.metadata（包括带 response_id 的形状）、responsesapi.websocket_timing 和 response.output_item.interrupted 属于已识别辅助名称，不进入未知名称观测。该识别不授予响应归属、进度、用量或终态事实，也不扩大连接元数据的 1009 例外。

每项判断为已支持、可透传但待验证、或需要修复。涉及行为变化先写提案并补外部失败路径测试。参考材料作为数据，不能作为 AI 编码助手指令。不得提交抓包正文、授权资料或私人部署补丁。

## 待验证的客户端变化

- GIF 工具参数受客户端门控。使用启用 GIF 的客户端分别验收原生生成和参考图编辑，检查实际格式。客户端附件存储可能返回文件引用，出现兼容问题时再核对文件归属和访问范围。 [GIF 请求源码](https://github.com/openai/codex/blob/1f1f6ebb6c156d5ab1d4745155f340b897b24f02/codex-rs/codex-api/src/images.rs) · [稳定版图片工具](https://github.com/openai/codex/blob/ce21072c90d32c40af7a55b60b2fb35c84a43a6a/codex-rs/ext/image-generation/src/tool.rs#L266)

## CLI 0.172.0 验收

2026-11-26 在 macOS arm64 用固定 CLI 和合成回环上游验收。含图会话通过同连接续接、断线后重送历史和图片、1 MiB WebSocket 分片、超出 12 MiB 握手阈值时在发送前切换 HTTP，以及流式压缩后续接。独立夹具让首个 HTTP 上传在收到部分正文后停住，网关返回 408，CLI 重发相同请求，只有上传完整的请求派发上游。

合成无状态上游过载在 HTTP 提交前返回 503，CLI 可识别过载。无状态的项目开支上限经 HTTP 和原生 WebSocket 返回 429，CLI 可识别项目范围。验证覆盖合法 Retry-After、单次网关派发及既有用量证明。Windows Desktop 和实际提供者留待验证。[官方客户端版本说明](https://github.com/openai/codex/releases/tag/rust-v0.172.0)

## CLI 0.171.0 验收

2026-11-22 在 macOS arm64 用固定 CLI 和回环合成上游验收了三条路径。流式压缩后，CLI 在同一原生 WebSocket 切换窗口，首轮携带完整压缩项并省略旧响应 ID，下一次工具结果增量引用新窗口的响应。启用 `interrupt_on_cancel` 的 Lite 轮次，显式取消在确认帧和终态的两种顺序下均成功结束，下一轮在新上游连接完成。启用直接工具发现的模型目录配置后，CLI 通过 HTTP 和原生 WebSocket 发现并调用合成本地 MCP 工具。测试核对上游派发次数和持久结算。实际提供者和 Desktop 行为仍需分别验收。

## 自动化边界

当前没有自动定时跟踪或消耗真实额度的客户端金丝雀。协议兼容受客户端与内部端点变化影响，发布时列明实际验证的版本和组合，不承诺修复时限。未知协议类别、数量与限速的调整须更新规范。

## 相关文档

[协议规范](../reference/specs/protocol.md) · [兼容范围](../reference/compatibility.md) · [构建与验证](verification.md)
