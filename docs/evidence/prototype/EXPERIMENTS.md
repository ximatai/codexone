# CodexOne Swift 传输实验报告

日期：2026-10-21。环境：macOS arm64，Swift 6.4，Debug 构建。Python/aiohttp 合成上游，全部连接为 loopback。没有真实 Codex/OpenAI 请求、账号或费用。

## 结果

| 路径 | 通过 | 失败 |
|---|---:|---:|
| Vapor 高层 HTTP 对照路径 + Vapor/NIO WebSocket | 11 | 2 |
| 显式 NIO HTTP 生命周期 + Vapor/NIO WebSocket | **13** | **0** |

[默认路径原始报告](artifacts/verified-macos.json) · [高层 HTTP 对照报告](artifacts/baseline-vapor-macos.json)

| 默认路径实验 | 结果 | 用时 |
|---|---|---:|
| SSE incremental UTF-8 and unknown fields | 通过 | 0.536 s |
| Upstream error transparency | 通过 | 0.004 s |
| Multipart binary preservation | 通过 | 0.034 s |
| Image JSON envelope preservation | 通过 | 0.003 s |
| WebSocket ordering, preconnect queue and binary | 通过 | 0.096 s |
| Fragmented WebSocket aggregate limit | 通过 | 0.008 s |
| Upstream WebSocket close propagates | 通过 | 0.004 s |
| Active SSE client disconnect cleanup | 通过 | 0.055 s |
| Quiet upstream client disconnect cleanup under 2s | 通过 | 0.054 s |
| Disconnect before upstream response headers | 通过 | 0.054 s |
| Slow HTTP reader bounds buffering | 通过 | 1.026 s |
| 50 concurrent streams finalize once | 通过 | 0.130 s |
| HTTPS and WSS through HTTP CONNECT | 通过 | 0.138 s |

## 发现与处理

### HTTP 静默断连

高层流式路径中，活跃上游的下游写入失败可以驱动清理，但上游静默或尚未返回响应头时，客户端断开没有在 2 秒门槛内终止上游操作。

原型增加一层 NIO HTTP listener，通过 `channelInactive` 取消对应 Task。单独这样做仍未通过静默场景：指标显示 FIN 尚未送达 handler。核对源码后发现默认 HTTP pipelining assistance 在响应未完成时暂停读取，延后了关闭事件观察。关闭这一辅助行为后，两项实验通过：静默回收约 51.59 ms，响应头之前回收约 3.06 ms（后者受 50 ms 轮询步长影响，均为单次本地观测）。

也尝试了空字节写入探测，未解决问题；已弃用，没有通过人为拉长超时或屏蔽失败来使测试变绿。

当前 NIO listener 每连接只处理一个 HTTP 请求并关闭，显式拒绝流水线请求。未验证 HTTP keep-alive 复用、HTTP/2、反向代理前置后的关闭传播。后续正式实现需要保持关闭事件可见，同时定义复用策略。

### WebSocket 消息边界与资源上限

Vapor 便捷路由的 maxFrameSize 不等于聚合消息上限。原型使用公开 NIO upgrader 设置单帧、分片聚合总量及分片数量限制。34 个 64 KiB 分片超过 2 MiB 时被关闭，未转发到上游。每方向队列及建连前队列同时限制 4 MiB 和 1024 条，避免空消息绕过字节预算。队列溢出的压力阈值尚未单独做故障注入测试。

100 条文本按序返回，512 KiB 二进制一致；注入上游 1011 关闭码后，下游得到同一关闭码。

### 背压与内存观测

本地慢读实验让上游尝试输出 256 MiB，客户端停止主动读取 1 秒。网关这时只读取约 0.81 MiB，RSS 从 26,640 KiB 到 26,720 KiB。它证明该短实验中没有把整个响应缓存在内存，不能当作长期内存上界、容量或性能基准。

SSE 首字节观测约 10.24 ms；TLS 使用临时专用 CA 并保留证书验证，HTTPS 与 WSS 均经过 CONNECT fixture。未覆盖代理认证和 SOCKS 出网。

## 判断

**Swift + Vapor + SwiftNIO + AsyncHTTPClient 足以实现这里验证的核心传输行为。** 需要显式设计传输层，而不能仅把普通 Vapor 路由和几段 async/await 拼起来就视为可靠代理。

本报告不证明完整 Codex 协议兼容。后续顺序建议：Linux Docker 验证 → 真实 Codex 多轮/工具调用兼容 → 账号刷新与出口绑定 → 持久化额度/结算 → 崩溃恢复与长时间故障测试。

multipart 当前为 20 MiB 上限的收集转发，图片只是合成 JSON 透传，生命周期终态计数不是账单结算。并发实验为 50 路短流，不是生产容量结论。上述 macOS 实验完成时尚未部署或推送。随后创建公开仓库并执行了下面的 Linux CI；Ali 未改动。


## Linux GitHub CI 验证

2026-10-21 在 GitHub 原生 `ubuntu-24.04` amd64 runner 上，通过 `swift:6.4-noble` 构建 Release 程序，以 `swift:6.4-noble-slim` 为运行基底，在同一容器内运行 fixture 与程序。默认 NIO HTTP + Vapor WebSocket **13/13 通过**。

- [首次 CI 运行](https://github.com/ximatai/codexone/actions/runs/39599507190)，验证源码提交 `fcc441255ecba731e65c100a43f4c0238fb8ce44`。
- [Linux 原始报告](artifacts/verified-linux-amd64.json)：`runtime.system=Linux`，`runtime.machine=x86_64`。
- 静默上游断连回收约 51.12 ms；响应头返回前断连回收约 1.31 ms（单次观测）。
- 慢读期间 RSS 41,440 → 41,448 KiB；上游提供 256 MiB，网关在取消前读取约 2.78 MiB。仍只是短时采样。
- 运行镜像压缩产物约 123 MiB，随 CI 提供下载，保留 7 天；报告与日志保留 14 天。原始 JSON 随源码保存。

本轮补足 Linux amd64 动态运行库、Release 编译、非 root 容器执行和 13 项传输实验的实际证据。未验证 ARM Linux、真实 Codex、生产账号或 Ali 容量。没有部署服务器或发布到镜像仓库。


## 真实 Codex 协议验证

2026-10-21，本机 macOS arm64，Codex CLI 0.163.0，`gpt-6.1-sol`。CLI 使用临时 Codex home 和工作区，连接本机 Swift 网关；网关通过本地 HTTP CONNECT 代理连接真实 ChatGPT Codex 上游。读取已有单账号凭证，不刷新、不修改原登录文件；消耗该账号正常用量，未修改 Ali 部署，也未通过现有 codex-lb 转发。

[无凭证原始证据汇总](artifacts/verified-codex-macos.json) · [本机协议契约结果](artifacts/verified-responses-contracts-macos.json)

| 场景 | 实际结果 |
|---|---|
| HTTP 普通对话、关闭 CLI 后续接 | 通过 |
| WebSocket 普通对话、关闭 CLI 后续接 | 通过 |
| HTTP / WebSocket shell 读取临时文件、工具结果回传 | 均通过；有 command_execution 事件及网关字节指标 |
| 131,214 字节长输入中的标记检索 | 通过 |
| 声明 V2 能力、16k token 阈值自动压缩后续接 | 通过；持久化 compacted 记录 1 条，标记保留 |
| 原生图片扩展调用 | 实际产出 1,190,878 字节 PNG；同时确认原生 Images 请求经 Swift 完成 |
| 旧 `/responses/compact` 真实上游探测 | **404，未通过**；保留诊断失败，不能宣称旧接口兼容 |

### 两处兼容细节

1. WebSocket 鉴权拒绝后，当前 Vapor 升级管线的连接复用会让下一次升级等待。拒绝响应显式关闭连接后，同一个客户端能重新建立连接并升级；契约回归覆盖这一路径。
2. Codex 0.163.0 的原生图片扩展并非仅由模型名称决定。对应版本源码的 `ImageGenerationExtensionConfig::from_config` 检查 provider 是否为 OpenAI、是否要求 OpenAI 登录，或是否声明 actor authorization。实验客户端为自定义 provider 增加非空 `x-openai-actor-authorization` 声明，并提供 `/v1/images/generations` 入口后，真实图片请求成功；网关移除此声明，以配置的上游 token/account 发起请求。图片入口目前原样转发，不包含 Images → Responses 转换器。

源码依据：[图片扩展可用性](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/ext/image-generation/src/extension.rs)、[原生 Images 路径](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/codex-api/src/endpoint/images.rs)。新版压缩能力说明见 [官方配置参考](https://developers.openai.com/codex/config-reference)。

图片测试最初缺少 provider 声明，确实未暴露原生工具；补上后真实生成成功。另一版测试脚本误以为 CLI JSON 一定包含图片专用 item，导致已有 PNG 时仍报失败；最终改为核对目标 PNG 与网关 Images 请求证据。它不是上游图片失败。随后独立旧 compact 探测返回 404，整个诊断脚本仍以失败退出，原始报告没有隐藏这项不支持。

当前结论只适用于这一个版本、模型、账号和已执行场景。尚未证明全部 Codex 功能、图片编辑、超过实验限额的历史图片、大规模上下文、多账号安全、取消后重试、故障恢复及生产负载。HTTP 与 WebSocket 仍分属两个端口。


### Linux 回归

[Linux CI](https://github.com/ximatai/codexone/actions/runs/39604341742) 在源码提交 `8acff23` 上成功完成：Release 编译、非 root 容器执行、13 项原有传输实验以及 11 项协议契约检查全部通过，并导出运行镜像。

[Linux 传输回归原始报告](artifacts/verified-transport-protocol-linux-amd64.json) · [Linux 协议契约原始报告](artifacts/verified-responses-contracts-linux-amd64.json)

Linux CI 没有执行真实账号 CLI 请求；真实 Codex 客户端证据来自上面的 macOS 本机实验。
