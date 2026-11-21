# Connector 工具结果兼容探针

使用 Python 3 标准库、Codex CLI 0.171.0 和 Rust 网关。探针为每个场景分配临时目录、动态回环端口、合成身份和独立客户端配置。stdout 只输出断言结果。

```sh
cargo build --locked --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/cli_tool_results/probe.py \
  --codex codex --binary rust/gateway/target/debug/codexone
```

## CLI 实测

2026-11-21 在 macOS 27.2.1 arm64 运行 Codex CLI 0.171.0，使用自定义回环 Responses 地址、合成 ChatGPT 登录和本地 Hosted Apps。Code Mode `exec` 调用合成连接器一次，随后只把固定的普通输出写入模型上下文。测试启用 `output_token_replay`，自定义 provider 名称使用大小写精确的 `OpenAI`，以触发第二个 include 选择器。直接监听 CLI 的请求可独立观察客户端生成的正文。

| 场景 | 观测 |
| --- | --- |
| 原生 WS | 首帧 `generate:false`，随后两次生成。工具输出通过增量请求发送，`previous_response_id` 指向上一响应。 |
| CLI 回退 | 收到带普通工具输出的增量帧后，回环服务发 1009。CLI 用原账号和 Bearer 发起 HTTP，恢复完整输入，普通工具输出仍在。 |
| 私有正文 | 两路在 CLI 的显式 `mcp_tool_call` 结果事件里均收到合成标记。预热、WS 生成和 HTTP 回退的采样请求都没有标记或 `tool_result`。开启的 WS trace 和客户端 stderr 中均没有明文或十六进制标记。显式工具事件是调用方可见输出，含该结果。 |
| include | 每个请求按原顺序带有 `reasoning.encrypted_content` 和 `output.encrypted_content`。 |

## 网关合成请求实测

在同一平台从 CodexOne 基线 `c3f4d7a9001ca783c9a0c36f76c5c0c9624e84a3` 构建 Rust 网关。手造输入在 `input[*].internal_chat_message_metadata_passthrough.executed_tool_calls[*].tool_result` 放入合成文本和对象型 `structuredContent`，复现网关收到该扩展字段后的行为。协议边界见[协议规范](../../../docs/reference/specs/protocol.md)。

| 场景 | 观测 |
| --- | --- |
| 网关原生 WS | 合成预热在前，生成在后。预热输入为空。生成请求的嵌套调用行和结果完整到达上游，本地输出对象 ID 被移除。两次执行均在同一合成身份下结算。 |
| 网关桥接回退 | 下游 POST 先桥接到上游 WS。上游在任何处理事件前返回 1009，网关以同一上游 Bearer 改走 HTTP，两个上游请求都带完整结果，库中只有一条同身份的 settled 记录。 |
| include 与日志 | 原生、预热和桥接两段均保留原数组。网关日志可见固定的 `http_1009` 诊断，采集到的日志没有明文或十六进制的合成标记。 |

## 上游源码核查

- 稳定 tag 指向 `ccf9be8cc458bd6b8336fe84d68d8893f2691a5e`。与两个 PR 的合并提交比较，公共基线均为 `1b84166252b6ecfd36be9e12c29ac01454a30d7e`。稳定版从合并前的分支发布。其请求构造始终加入 reasoning 选择器，开启 `output_token_replay` 且 provider 名称精确匹配 `OpenAI` 时追加 output 选择器。[0.171.0 发布](https://github.com/openai/codex/releases/tag/rust-v0.171.0) · [#62388 提交比较](https://github.com/openai/codex/compare/rust-v0.171.0...f1b69864161866a111610c4b4351d397fb644b6f) · [#62474 提交比较](https://github.com/openai/codex/compare/rust-v0.171.0...083bf59b6b01582f62171249f6a6ff0686928229) · [稳定 tag 的请求构造](https://github.com/openai/codex/blob/rust-v0.171.0/codex-rs/core/src/client.rs#L1285-L1288)
- #62388 提供可选的 HTTP/WS 序列化能力，默认请求未填结果正文。它保留文本及对象型 `structuredContent`，按单结果 1 MiB 和增强消息 15 MiB 限额处理。HTTP 对原目的地的重试保留增强正文，处理 307/308 时使用原 JSON。结果关联 ID 保留在客户端。[#62388](https://github.com/openai/codex/pull/62388)
- 到 #62474 合并点，`connector_tool_result_passthrough` 默认关闭。开启后还须走第一方 ChatGPT 认证路径，拥有当前账号、允许内部元数据，且经允许的 Hosted Apps 调用能匹配当前 turn 和本次实际输入中的执行记录。目的地仅允许 `https://chatgpt.com/backend-api/codex` 或 `https://chatgpt-staging.com/backend-api/codex`，两者可带一个结尾斜杠。额外的 Responses 路由头、查询参数及白名单以外的 provider 头均影响资格。每次 WS 尝试重新判断，预热省略结果；WS 增量只匹配本帧输入。自定义域名和回环地址均在此目的地白名单之外。[开关](https://github.com/openai/codex/blob/083bf59b6b01582f62171249f6a6ff0686928229/codex-rs/features/src/lib.rs#L1333-L1337) · [收集条件](https://github.com/openai/codex/blob/083bf59b6b01582f62171249f6a6ff0686928229/codex-rs/core/src/tools/executed_tool_calls.rs#L468-L562) · [目的地条件](https://github.com/openai/codex/blob/083bf59b6b01582f62171249f6a6ff0686928229/codex-rs/core/src/client.rs#L285-L332) · [WS 预热与实际帧](https://github.com/openai/codex/blob/083bf59b6b01582f62171249f6a6ff0686928229/codex-rs/core/src/client.rs#L2637-L2648)

实际执行范围为稳定 CLI、合成 Hosted Apps 和固定身份 Rust 网关。官方目的地上的授权正例、跨账号轮换及 HTTP 重定向属于上面的源码核查范围。探针对网关日志的结论限定在这四条路径及该合成标记。
