# 迁移就绪：客户端标识、明确拒绝结算与连接容量

日期：2026-10-31。正式迁移全部 Key 前，需要补齐三项与旧服务（CodexLB）的差距。用户决定见下文；本变更修改 [协议](../../specs/protocol.md)、[用量](../../specs/usage.md) 和相关运行限制。

## A. 非 Codex 客户端的上游标识统一

用户会用 Claude Code，或经 magpie 等中转把网关提供给 Codex 与 Claude Code 使用。提供者会以 403 拒绝非 Codex 标识的图片请求。旧服务对所有非原生请求都统一改为 Codex CLI 标识，在 HTTP、WebSocket 和 Images 上都这样做（CodexLB `outbound-http-clients` 规范“Non-native upstream requests use the Codex CLI client fingerprint”）。账号对提供者一直表现为 Codex 客户端，照此对齐不增加风险。

- **原生判定**：入站 `User-Agent` 以 `codex_cli_rs`、`codex-tui`、`codex_exec`、`codex_sdk_ts`、`codex_vscode`、`Codex Desktop` 或 `Codex ` 开头，或者 `originator` 属于原生集合（至少包括 `codex_cli_rs`、`codex_vscode`、`codex_sdk_ts`、`codex_exec`、`codex_chatgpt_desktop`、`Codex Desktop`）。`x-codex-*` 续接头不作为原生信号。
- **原生请求**：标识头不变，继续按现有允许列表转发。
- **非原生请求**：
  - 去掉入站的 `user-agent`、`originator`、`version`（不区分大小写）；
  - 改为设置 `user-agent: codex_cli_rs/<version> (<os>; <arch>) <terminal>`、`originator: codex_cli_rs`、`version: <version>`；
  - `x-codex-*` 续接头照常按允许列表保留；
  - SDK 特征头（`x-stainless-*`、`x-openai-client-*`）本来就不在允许列表内，需用测试锁定。
- **配置**：标识取值由私有配置可选的 `clientFingerprint {version, os, arch, terminal}` 决定。
  - `version` 缺省取模型 profile 快照 `clientVersions` 中最大的版本，没有快照时取编译内置的默认值；
  - `os`、`arch`、`terminal` 缺省为 `Mac OS 26.5.0`、`arm64`、`iTerm.app/3.6.10`；
  - 取值须为有界的可打印 ASCII；
  - 请求路径上不发起任何网络查询。
- **适用路径**：Responses HTTP、compact、原生 Images、控制接口，以及上游 WebSocket 握手。
- **上游 WebSocket 握手**：目前不带任何客户端标识。改为与 HTTP 一致：原生请求转发允许列表内的标识头，非原生请求使用统一标识。
  - 以每个下游连接或请求的入站头为准。
  - 桥接（HTTP 下游转 WS 上游）使用该 HTTP 请求的入站头。
- **不变项**：账号认证头仍由服务注入；`x-openai-actor-authorization` 等门控头仍不转发。

## B. 明确拒绝零费用结算

用户决定：提供者在**产生任何输出之前**明确拒绝时，执行结算为失败，零用量，不再挂 unknown。

- **适用情况**：
  - Responses/compact/Images 的 HTTP 上游返回 4xx 响应头（含 429，包括响应体不可读的情况）；
  - 上游 WebSocket 握手被 4xx 拒绝；
  - 上游流（SSE/WS）在任何输出条目或 delta 之前，以 `error` 或 `response.failed` 作为首个事件给出明确的 4xx 状态或错误码。
- **结算**：settled、outcome failed、failure 沿用现有分类（如 `upstream_rejected`、限流）；可信用量为零，完整度为 complete，并在 usage JSON 中以可选标记注明“提供者在输出前拒绝”；释放 unknown 暴露与预留，计费为零。
- **仍按现行规则记 unknown/partial**：5xx、超时、断线、取消、已有任何输出后的失败，以及拒绝依据无法确认的情况。
- **不追溯**：历史 unknown 不改写；不改 schema 版本。
- 规范同步：[用量](../../specs/usage.md) 中“缺失证据保留 unknown”的一般规则增加此例外，并写明其边界。

## C. 数据面连接容量与上游连接

- **现状问题**：数据面全局只接受 8 个普通连接，另有 8 个连接留给控制接口。单个 Desktop 就会同时保持 2 个以上长期 WebSocket，再加上 warmup 和并行辅助请求，迁移 17 个 Key 后必然不够。
- **连接上限可配置**：私有配置增加 `dataConnections`，缺省 128，允许范围 8—1024；控制接口专用的额外余量保持固定的 16。
  - 握手期限、请求体共享预算、Key 与全局并发限制不变，公平性仍由 Key 并发限制保证。
  - 用合成负载测量空闲 WebSocket 与活动连接的内存和文件描述符占用，证据写入验证记录。
- **上游 HTTP 连接**：
  - 连接期限由 5 秒放宽到 10 秒，并允许在请求发送前重试建立连接（在原请求期限内，有界）。请求发出后的失败仍不重放。
  - 上游 WebSocket 的连接期限同步放宽到 10 秒。
  - `maximumUsesPerConnection = 1` 保持不变：避免复用陈旧连接，导致请求发出后才失败、变成 unknown。
- **依据**：测试实例上独立搜索有 2/13 次在 5007 ms 时因连接超时返回 502，客户端重试后成功。

## 排除

- 不做 UA 版本的在线查询；
- 不修改原生客户端的标识；
- 不改变账号调度、计价或 schema；
- 不追溯历史账本。

## 验收

- **A**：
  - 单元测试覆盖原生/非原生判定（UA 与 originator 各种变体、续接头不算原生信号）和配置边界；
  - socket 测试中，HTTP、Images、控制接口、桥接 WS 和原生 WS 握手在非原生入站时上游收到统一标识，原生入站时保持原值；
  - SDK 特征头、门控头和认证类头不出现在上游请求中。
- **B**：
  - 合成上游覆盖以下情况，均结算为 settled/failed、零用量、complete，并释放暴露：
    - HTTP 400/403/429 以及响应体不可读的 4xx；
    - WS 握手 4xx；
    - 首事件为 `error` 或 `response.failed`；
  - 以下情况仍为 unknown：5xx、超时、断线，以及先有输出后出错；
  - 用量查询和费用显示为 0。
- **C**：
  - 配置边界测试；
  - 超过 8 个并发连接的合成测试（如 64 个 WebSocket 加 HTTP），到达上限时的拒绝行为保持；
  - 控制接口余量仍能返回 429；
  - 上游连接重试只发生在发送前，有测试证明发送后的失败不重放；
  - 记录内存与描述符的测量结果。
- 完整 `verify.sh --backend` 与 Linux verification 通过。
