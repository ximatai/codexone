# 客户端续接与恢复契约

核实日期：2026-10-22。依据是明确版本的源码、官方协议和本项目合成上游上的实际 CLI；不代表 Desktop 或真实订阅验收通过。

## 已观察的客户端路径

| 路径 | 已验证行为 | 可推导范围 |
|---|---|---|
| Codex CLI 0.163.0 HTTP/SSE，私有临时配置 | 文本/函数结果/加密推理完整窗口回传，采用明确的合成模型指导，无 metadata fallback | 正常客户端上下文可继续作为新生成输入；不等于保留客户端默认指导 |
| 同版本 HTTP/SSE，response.created 后无终态 EOF | CLI 显示 Reconnecting，再 POST responses；两个持久 attempt 分别 unknown、settled | 客户端重连可能产生新执行，不是读取先前输出，也不能自动释放原预留 |
| 网关原生 WS 合成 socket | 同 socket 的 previous_response_id、warmup、跨 lane 归属及完整窗口续接 | 协议实现证据，不是实际客户端断线恢复 |
| Codex CLI 0.163.0 原生 WS | 一次 warmup、两个生成，previous_response_id 依次指向预热及函数调用响应，共用一个上游 socket | 正常连接内的实际 CLI 续接；不证明断线后的输出读取或 Desktop UI |
| 同版本 remote_compaction=v2，三传输 | 工具结果后实际触发普通 Responses 上的 compaction_trigger，重建窗口携完整 compaction 后继续生成 | 正常压缩与主动后续生成；不是重读旧执行或自动补回断线输出 |
| Desktop 内置 CLI 0.163.0-alpha.11（独立命令行运行） | 临时隔离配置下三传输文本/工具、v2 压缩及后续 opaque 输入通过；原生 WS 一次预热、单上游连接；HTTP EOF 后新执行与缺 profile fallback 同样可复现 | 缩小与 Homebrew CLI 的版本差异；没有运行 Desktop UI，不能作为其操作验收 |
| Desktop 26.1016.51333（21161，内置 CLI 0.163.0-alpha.11） | Computer Use 明确禁止控制 com.openai.codex，未绕过 | 无实际 Desktop 操作/恢复结论；CLI 不能替代它 |

CLI 检查入口为 `scripts/verify_client.py`，加 `--retry-probe` 验证 EOF 后新执行。使用公开合成 Key、临时 CODEX_HOME/空目录与只读 sandbox；provider 重试上限 1，不触碰真实账号。probe 第一执行不返回工具调用，避免把重复工具执行引入本次实验。

## 续接与输出读取的区别

[官方 WebSocket 协议](https://developers.openai.com/api/docs/guides/websocket-mode)把 previous_response_id 用于新响应上下文关联；store=false 的可用性依赖连接缓存，缓存丢失时可由持有完整输入的客户端重建。这并不保证原执行输出可重新读取。

[CLI 0.163.0 的 client.rs](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/src/client.rs)显示 store=false、预热复用与 HTTP fallback；本项目对 EOF 的实际探针进一步证明该场景发出新 create。仅从这些代码和探针，不能推导 Desktop 会 GET 已有响应、按事件位置续读，或可识别网关 attempt ID。

当前网关没有输出读取或重放路由，也没有正文缓存。持久 response/item/context 归属用于阻止跨主体引用；它不证明提供者仍保留对象，更不证明客户端已消费输出。网关重启会失去 WS 上游连接缓存，已知归属不能让远端对象重新出现；HTTP→WS 每执行新建连接，同样不承诺 store=false 跨请求缓存。

## M5 的未决出口

现有证据不足以承诺 Desktop 原生透明恢复。M5 实现正文/图片缓存之前，仍须证明一种明确客户端版本实际可使用的读取路径，记录关联 ID、认证、消费位置与工具重复风险。独立管理台人工导出或新恢复客户端是可能的产品调整，尚未采纳，不能自行用私有协议替代原目标。

下游断开、上游关闭、网关重启和对象过期分别验收；没有可信终态时保留 unknown。不得因为客户端显示 Reconnecting，就把新的模型/工具执行称作原输出恢复；也不得根据输入相同自行重放、合并、退款或跨身份重试。恢复范围调整按 C10/C11 和里程碑出口处理。

## M5 复核

同日再次执行 CLI 0.163.0 的隔离 EOF 探针，仍观察到 unknown + 新生成 settled。公开 Responses API 有 GET response/starting_after，但尚无目标 Codex 客户端读取它的证据，也没有订阅提供者等价性证明。复核命令、来源和结论见[契约核实](../changes/recovery-contract-audit/verification.md)。M5 不因标准 API 存在就通过 C10；后续只读证据或明确产品调整方可解除该边界。
