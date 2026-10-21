# CodexOne · Swift 传输层验证实验

[![Linux transport verification](https://github.com/ximatai/codexone/actions/workflows/linux.yml/badge.svg)](https://github.com/ximatai/codexone/actions/workflows/linux.yml)

许可证：[MIT](LICENSE)。

这是独立的 **Swift + Vapor 技术可行性原型**，不是完整的 codex-lb 重写版。程序只绑定 `127.0.0.1`。默认传输实验的上游限制为 loopback，使用本地合成数据，不读取账号、不连接 OpenAI、不生成真实图片、不计费。另有显式启用的真实 Codex 协议验证，会连接指定上游并消耗测试账号的正常用量。

## 运行

需要 Swift 6.4、Python 3.11+、`uv` 和 `openssl`。首次构建会下载并编译 SwiftNIO、TLS 等依赖；后续运行使用缓存。

```sh
cd codexone
./scripts/verify.sh
```

也可以分步运行：

```sh
swift build -j 6
uv run scripts/verify_transport.py
```

对照高层 Vapor HTTP 路径（预期暴露两项断连回收缺口，退出码为 1）：

```sh
uv run scripts/verify_transport.py --http-mode vapor
```

只重跑某一项实验：`uv run scripts/verify_transport.py --only Quiet`。

脚本自动启动 HTTP、TLS、WebSocket 模拟上游、HTTP CONNECT 代理及 Swift 服务，结束时关闭它们。报告和服务日志写入 `artifacts/run-*/`。失败的实验保留失败状态并返回非零退出码，不隐藏技术缺口。

## 架构

- Vapor 4.122.2：HTTP 路由、流式响应、管理实验指标。
- AsyncHTTPClient 1.36.2：上游逐块读取、TLS、连接池、HTTP 代理。
- WebSocketKit 2.16.2：客户端/服务端 WebSocket。
- SwiftNIO 2.104.0：自定义升级器，显式限制**单帧与聚合消息**。
- Swift 6 并发检查；每个 WebSocket 方向只有一个有序发送任务，队列限制为 4 MiB / 1024 条消息（含建连前排队），溢出则明确关闭连接。
- HTTP 下游写入完成后才继续读取下一块，不累积整个 SSE 响应。
- 默认实验 HTTP 数据面使用小型 NIO listener：拥有 channel 的关闭事件，关闭时取消上游 Task。
- 该 listener 关闭 HTTP pipelining assistance，否则长响应期间读暂停会延后 FIN 识别。原型每连接只处理一次 HTTP 请求后关闭；尚未实现 keep-alive 复用或 HTTP/2。
- Vapor 的 HTTP 路径保留为对照组；WebSocket 和指标接口仍走 Vapor。两个 listener 在同一进程共享配置、客户端和状态。
- `Package.resolved` 固定传递依赖；当前依赖组合需要 Swift 6.4。

## 实验范围

1. SSE 增量首包、UTF-8 跨块、未知字段保留。
2. 上游 429、Retry-After 和错误 JSON 透传。
3. 2 MiB multipart 二进制及 Content-Type 保留。
4. 合成图片 JSON/usage 响应透传。
5. WebSocket 建连前消息排队、有序文本、512 KiB 二进制。
6. 上游关闭与下游关闭传播。
7. 活跃/静默上游的客户端断开回收，以及上游返回响应头之前断开。
8. 慢 HTTP 客户端下的读取量和 RSS 采样。
9. 50 路并发流的终态只记录一次。
10. HTTPS/WSS 通过 HTTP CONNECT，信任专用临时测试 CA，保持证书验证。

`terminalTransitions` 只是实验生命周期指标，**不代表已经实现账单幂等性**。multipart 第一版是最多 20 MiB 的有界收集，不是流式 multipart 解析。图片实验不验证图像生成能力，也不验证 OpenAI 的协议兼容细节。

## 手动配置

| 环境变量 | 用途 |
|---|---|
| `LAB_PORT` | 本地监听端口，默认 18080 |
| `LAB_TRANSPORT_PORT` | NIO HTTP 数据面端口，默认 LAB_PORT + 1 |
| `LAB_UPSTREAM` | loopback 上游，默认 `http://127.0.0.1:18081` |
| `LAB_PROXY_HOST` / `LAB_PROXY_PORT` | 配对设置 HTTP 代理 |
| `LAB_CA_FILE` | 用于本地 TLS fixture 的 CA 文件 |

Vapor 端口的接口：`/health`、`/relay/sse`、`/relay/ws`、`/relay/status`、`/relay/upload`、`/relay/image`、`/lab/metrics/:id`。NIO 数据面端口支持 HTTP `/relay/*`，WebSocket 使用 Vapor 端口。测试脚本自动分配端口。所有接口均为实验用途，未提供生产鉴权，不应暴露公网。

## 尚未证明

完整 Codex 功能覆盖、账号 OAuth/刷新、SOCKS5/5h 与代理认证、跨账号安全边界、限额与持久化结算、进程崩溃恢复、ARM Linux 容器运行、长时间压力测试。它们需要后续独立实验，不能从本原型通过自动推断。


## 当前结论

已在本机 macOS arm64 / Swift 6.4 实测，默认 NIO HTTP + Vapor WebSocket 组合 **13/13 通过**，详见 [实验报告](EXPERIMENTS.md) 和 [原始 JSON](artifacts/verified-macos.json)。GitHub CI 的 Linux amd64 / Swift 6.4 Release 容器也已实测 **13/13 通过**，见 [Linux 原始 JSON](artifacts/verified-linux-amd64.json) 和 [首次 CI](https://github.com/ximatai/codexone/actions/runs/39599507190)。高层 HTTP 路径的断连行为与失败基线同时保留。空写探测没有解决问题，已从最终实现移除。

这说明 Swift 生态能够实现所测试的核心传输行为，也证明部分长连接生命周期需要下沉到 NIO 显式控制。它不证明纯 Vapor 高层接口已开箱即用地覆盖生产网关，也不是吞吐量对比或长期稳定性结论。


## GitHub CI 与 Linux 镜像

GitHub Actions 在原生 amd64 Linux runner 上构建 Swift 6.4 Release 镜像，然后在容器中运行默认路径的 13 项传输实验及 11 项 Responses 契约检查。push、pull request 和手动触发均可运行，不需要 OpenAI 密钥，也不访问 Ali。第三方 Actions 固定到提交 SHA。

成功后，Actions 提供两份下载产物：

- `linux-amd64-reports`：实验 JSON、服务日志，保留 14 天；失败时也尝试收集。
- `codexone-linux-amd64-image`：通过实验后导出的运行镜像压缩包，保留 7 天。标签含源码提交 SHA，可追溯版本。

当前只验证 `linux/amd64`，未验证 ARM Linux。运行镜像保留 Swift 动态运行库，但不包含编译器、Python fixture 或源码。镜像仍是仅监听 loopback 的实验程序，不能当作生产网关部署；没有自动发布 GHCR 或自动部署服务器的步骤。

本地 Docker 可复现（使用当前机器的原生架构）：

```sh
docker build --target verification -t codexone:verification .
docker run --name codexone-verification codexone:verification
# 即使实验失败，也可复制报告后再删除容器。
docker cp codexone-verification:/tmp/reports ./linux-reports
docker rm codexone-verification
```

生成运行镜像：`docker build --target runtime -t codexone:lab .`。首次编译在开发机或 CI 上完成，Ali 无需安装 Swift 编译器。容器验证覆盖合成上游的传输行为，不等于真实 Codex 或生产环境验证。


## 真实 Codex 协议实验

验收边界见 [协议验证要求](PROTOCOL-VALIDATION.md)。本机 Codex CLI 0.163.0 / `gpt-6.1-sol` 已实际通过 HTTP 和 WebSocket 的普通对话、会话重启续接、shell 工具调用及工具结果回传；HTTP 还通过约 128 KiB 长输入。启用 V2 能力后的真实自动压缩与续接、原生出图也已验证，详见 [真实协议报告](EXPERIMENTS.md#真实-codex-协议验证)。

无凭证的协议契约回归：

```sh
swift build -j 6
uv run scripts/verify_codex.py
```

显式进行真实测试（使用已登录 Codex 的账号，会消耗正常用量）：

```sh
uv run scripts/verify_codex.py --live \
  --upstream https://chatgpt.com/backend-api/codex \
  --auth-file ~/.codex/auth.json --transport http
# 将 transport 改为 websocket 测试 WebSocket；必要时增加 --proxy 127.0.0.1:7890。
# --long-context 增加长输入测试；--auto-compact 强制新版 V2 自动压缩并验证续接。
# --image 增加实际原生出图测试，--image-only 只测出图（目前要求 HTTP 模式）。
```

脚本在临时目录创建独立 Codex home 和工作区，运行结束删除；不修改现有 Codex 配置、登录文件或 Ali。上游 token 只注入 Swift 子进程环境，不写入生成的客户端配置，也不发送给测试 CLI。脚本不会刷新 OAuth token，过期凭证需另行处理。日志写入被 Git 忽略的 `artifacts/run-*/`；对外只保存经过选择的无凭证 JSON 证据。

手动启用代理需要同时提供 `LAB_RESPONSES_UPSTREAM`、`LAB_RESPONSES_TOKEN`、`LAB_RESPONSES_LOCAL_TOKEN`，可选 `LAB_RESPONSES_ACCOUNT_ID`。非本机上游必须为 HTTPS。NIO 端口处理 POST `/v1/responses`、`/v1/responses/compact`、`/v1/images/generations`；Vapor 端口处理 WebSocket `/v1/responses`。当前真实上游对旧 `/responses/compact` 返回 404；新版客户端使用声明的 V2 能力走 Responses 压缩，不能把旧接口的 fixture 透传通过当成上游支持旧接口。上游凭证替换客户端凭证，保留选定的协议头和原始 body；真实模式仍是单账号、双端口实验，不提供重试、刷新或生产鉴权系统。

测试客户端显式设置非空 `x-openai-actor-authorization` 声明，使 Codex 0.163.0 为自定义 provider 开放原生图片扩展；Swift 在上游请求中移除此声明。未声明时客户端可能只提示没有图片工具，不能据此断言上游模型不支持图片。
