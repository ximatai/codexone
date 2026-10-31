# 客户端协议跟踪

Codex 客户端会不经通知地新增线上协议，例如 WebSocket 中断消息 `response.interrupt`、新的 `x-codex-*` 请求头、`include` 选项或事件类型。网关不认识时，轻则悄悄丢弃，重则拒绝请求，客户端直接报错。

[前向兼容变更](../changes/client-protocol-forward-compat/proposal.md)已把网关改为“默认转发、以结果把关”。本页记录剩下的发现手段与待讨论的治理问题。目前不设自动定时任务，由主 Agent 不定期提醒用户，并在部署前手动执行检查。

## 发现手段

1. **网关日志**：未知 WS 控制消息与未知 `x-codex-*` 头会记录一条 `Client protocol extension` 结构化日志（类型名或头名、客户端版本、结果，不含内容）。部署后和日常巡检时查看新出现的名称。
2. **源码比对**（手动，建议每次部署前或每两周一次）：对比开源 Codex 自上次检查以来与线上协议相关的改动，重点路径：
   - `codex-rs/codex-api/src/`（WS 消息类型、事件类型、请求头）；
   - `codex-rs/core/src/client.rs`（Responses 请求字段、`include`）；
   - `codex-rs/core/src/session/turn.rs`（中断、转向等流程）；
   - `codex-rs/protocol/src/openai_models.rs`（模型目录字段）；
   - `codex-rs/features/src/lib.rs`（默认开启状态变化）；
   - `codex-rs/core/src/tools/spec_plan.rs`（工具门控）。

   每一项判断网关是“已支持”“默认转发应可用”还是“可能被拒绝或丢弃”，后者建变更处理。报告与参考克隆放在仓库外，不提交。
3. **新版客户端金丝雀**（候选，未启用）：用最新版 Codex CLI 对测试实例跑固定流程：普通对话、工具调用、中途停止、中途追加消息、压缩、生图。每次消耗少量真实额度。

## 治理决定（2026-10-31）

- 每次部署前由主 Agent 手动做源码比对，不设定时任务。
- 网关遇到的未知协议名称列入管理台首页[需要处理提醒](../changes/admin-attention/proposal.md)。
- 暂不做新版客户端金丝雀，不为跟踪消耗真实额度。

## 仍待讨论的治理问题

- 转发未知协议的边界是否要按类别收紧或放宽（例如未知 WS 消息的限速、`x-codex-*` 的数量上限）；
- 发现客户端协议变化后，修复和发布的时效目标。
