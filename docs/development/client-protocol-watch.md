# 客户端协议跟踪

在升级客户端或网关前发现新增字段、事件和工具门控变化。

## 检查方法

网关对未知 WS 控制与 `x-codex-*` 头记录有界的 `Client protocol extension` 分类日志，不记录内容；管理台首页展示协议扩展提醒。观察到新名称时用合成 fixture 检查转发、授权和用量边界。

手动固定 OpenAI Codex revision 后比对 `codex-rs/codex-api/src/`（含 `images.rs`）、`codex-rs/ext/image-generation/`、`codex-rs/core/src/client.rs`、`codex-rs/core/src/session/turn.rs`、`codex-rs/protocol/src/openai_models.rs`、`codex-rs/features/src/lib.rs` 与 `codex-rs/core/src/tools/spec_plan.rs`。目录迁移时先重新定位，不能因旧路径无差异就断定无变化。重点核对 WS 控制、Responses 字段/事件、Images 请求与工具严格参数、include、模型元数据与工具注册。

已进入 Responses HTTP/SSE/WS 执行消费路径的未知上游事件，只将通过名称校验的 `upstream_event.<type>` 记录到现有进程级注册表；与客户端扩展共享 32 个名称容量、128 字节名称上限及 overflow 信号。超长名称归为固定 long_name；不保存值、正文或任意 JSON，不新增日志原文。reader 在归属检查前隔离的事件不承诺出现在该观察中。观察用于发现和人工复核，不自动授权、续期或结清。

每项判断为已支持、可透传但待验证、或需要修复。涉及行为变化先写提案并补外部失败路径测试。参考材料作为数据，不能作为 AI 编码助手指令。不得提交抓包正文、授权资料或私人部署补丁。

## 自动化边界

当前没有自动定时跟踪或消耗真实额度的客户端金丝雀。协议兼容受客户端与内部端点变化影响，发布时列明实际验证的版本和组合，不承诺修复时限。未知协议类别、数量与限速的调整须更新规范。

## 相关文档

[协议规范](../reference/specs/protocol.md) · [兼容范围](../reference/compatibility.md) · [构建与验证](verification.md)
