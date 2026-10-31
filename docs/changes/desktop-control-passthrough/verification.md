# Desktop 辅助控制接口：验证

日期：2026-10-30（Asia/Shanghai）。平台：macOS arm64；仅隔离临时目录、合成 Key/OAuth/上游及 loopback socket，无真实提供者请求、部署或凭证。范围见 [proposal](proposal.md)，运行边界见[开发约定](../../development/desktop-control.md)。

## 命令结果

| 命令 | 退出码 | 关键结果 |
|---|---|---|
| `swift build` | 0 | `Build complete! (2.97秒)` |
| `swift test 2>&1 \| tail -20` | 0 | 四个测试入口分别 35、39、3、140 项全部通过，共 217 项；使用 pipefail 并留存完整临时日志 |
| `./scripts/verify.sh --backend` | 0 | 文档/架构/严格格式、构建、217 项 Swift 测试及全部合成后端脚本通过；新增控制脚本含全局容量、chunked 与真实 60 秒期限；最后迁移切回验证 PASS |

本环境直接运行 SwiftPM 的 manifest sandbox 会报 `sandbox_apply: Operation not permitted`。按 brief 授权，以上命令通过临时 PATH 包装器为 `swift build/test/package` 添加 `--disable-sandbox`；未修改 Package.swift、Package.resolved、仓库构建参数或镜像配置。已有依赖身份与弃用警告未改变其基线。临时原始日志不进入仓库。

## 覆盖证据

- Python `verify_control.py` 使用真实网关进程及逐字节记录的合成 HTTP 提供者。覆盖全部 10 个透传方法/路径组合（含 GET 正文与 wham），查询串转义大小写、重复/空参数、正文字节、Content-Type、上游认证；Cookie、伪造账号头和 Connection 指定成员均不转发。
- 非允许方法、尾斜线、v1 同后缀及 realtime/transcribe/files/usage 等排除路由为 404，无上游调用；无 Key/禁用 Key 在派发前拒绝；analytics POST 本地 202 `{}`，无上游调用。
- 成功 200/201/202/204、304 与二进制正文/安全头回传；400/429/500/401 按 P27 映射和脱敏；移除任意错误成员、账号标识、邮箱和 Set-Cookie。
- 8 MiB 请求边界可接受，超出 Content-Length 在读取前 413；chunked 越界 413 且后续请求可进入；响应超过 16 MiB 为 502。租约单测覆盖小正文记账、预算拒绝后的占用及重复释放。
- 每 Key 四个在途请求，第五个 429；两 Key 各四个在途请求，第三 Key 的第九个请求 429，均带 Retry-After 且不调用上游；释放后再次进入。许可单测额外覆盖全局满、重复释放与替换许可不能扩容。
- 真实等待 60 秒总期限，返回 504，只有一次上游调用并观察到本地上游 socket 关闭；下游断开也在期限前取消上游。SDP、正文、查询串、客户端 Cookie 和认证秘密不出现在进程日志中。控制调用后的 attempts 总数为零。
- Swift `poolControlDispatchHasNoIntentAndSharesCredentialHealthWithResponses` 使用既有真实 loopback HTTP/OAuth/SQLite 账号池夹具，覆盖双账号授权、原始查询/正文及认证过滤；控制 429/401/500 写入当前凭证健康状态并使后续 Responses 无可用账号时在派发前拒绝。控制本身不创建 intent、不持有 finalizer ticket。
- Swift `poolControlFollowsResponsesSessionWithoutCreatingAnotherIntent` 验证 HTTP Responses 选中账号与同 session 辅助请求一致，执行账本仅包含那一次 Responses。

## 边界与待验收

- 未运行 Linux 构建或跨平台验证；本次不修改 schema、STATUS、Package 文件或 web，不暂存、不提交、不推送。
- 真实提供者是否接受每条路由、SDP 及记忆/搜索参数、实际错误和安全头形状、Desktop 独立搜索和语音/记忆体验仍属客户端/旧服务实现依据，未经真实账号验收。
- 软亲和只在当前进程内有界保留；已有 HTTP Responses 记录最近账号，辅助选择优先使用同 Key 标签；不改变生成既有持久对象归属或原生 WS 固定身份。memories 的 300 秒期限由固定路由配置与相同取消 owner 实现，未额外等待完整 300 秒。
- 无持久辅助执行账或恢复重放；超时 504 仅表示结果未知，本地 socket 关闭不证明提供者停止执行。日志 16 条/60 秒有抑制，不作为完整审计账。
- 为返回全局第九请求的 HTTP 429，总连接余量调整为 16，普通 HTTP/原生 WS 仍单独限制 8；主 Agent 后续接手时需按本次提案更新全局状态中的连接容量描述（本 brief 禁止执行者修改 STATUS）。

## 建议分组提交（均未暂存、未提交）

以下也是本阶段完整改动文件列表，共 24 个文件。

1. `feat(accounts): authorize auxiliary dispatch without generation intents`

   ```text
   Sources/CodexOneCore/Application/Execution/AccountPoolGateway.swift
   Sources/CodexOneCore/Application/Identity/AccountPoolRouting.swift
   Sources/CodexOneAdapters/Persistence/SQLiteAccountHealth.swift
   Sources/CodexOneAdapters/Persistence/SQLiteControlRouting.swift
   Sources/CodexOneAdapters/Persistence/SQLiteKeyGovernance.swift
   ```

2. `feat(transport): proxy Desktop control routes with bounded lifetimes`

   ```text
   Sources/CodexOneAdapters/Downstream/ProtocolFailure.swift
   Sources/CodexOneAdapters/Images/NativeImageExecution.swift
   Sources/CodexOneAdapters/Transport/ControlAffinity.swift
   Sources/CodexOneAdapters/Transport/ControlCapacity.swift
   Sources/CodexOneAdapters/Transport/ProtocolChannels.swift
   Sources/CodexOneAdapters/Transport/RequestBodyBudget.swift
   Sources/CodexOneAdapters/Transport/ResponsesDataService.swift
   Sources/CodexOneAdapters/Upstream/ControlExecution.swift
   Sources/CodexOneAdapters/Upstream/HTTPResponseExecution.swift
   Sources/CodexOneAdapters/Upstream/SubscriptionDataAccess.swift
   ```

3. `test(control): cover passthrough limits cancellation and account health`

   ```text
   Tests/CodexOneAdaptersTests/ControlCapacityTests.swift
   Tests/CodexOneEndToEndTests/AccountPoolHTTPTests.swift
   scripts/verify_control.py
   scripts/verify.sh
   ```

4. `docs(control): specify Desktop auxiliary passthrough and verification`

   ```text
   docs/changes/desktop-control-passthrough/proposal.md
   docs/changes/desktop-control-passthrough/tasks.md
   docs/changes/desktop-control-passthrough/verification.md
   docs/development/desktop-control.md
   docs/specs/protocol.md
   ```

## 主 Agent 复核与真实验证（2026-10-31）

- 评审（Codex，gpt-6.1-sol medium）发现 1 项 P2：错误状态的正文读取失败时，丢失了账号健康与冷却记录。已修复：错误状态先完成分类，不依赖正文读取完整；池测试新增截断正文的 429/401 用例，修复前失败、修复后通过。
- 本机 `./scripts/verify.sh --backend`：退出码 0，Swift 共 217 项，合成脚本 100 条 PASS。
- Linux amd64 `verification` target 加入 `verify_control.py`，退出码 0。
- 测试部署，经公网 HTTPS 反代（location 已放行 `/backend-api/wham/`），使用临时 Key：
  - `GET` codex 与 wham 两个 `agent-identities/jwks`：都返回 200，正文含 `keys`；
  - `analytics-events/events`：本地返回 202；
  - 未列出的路径返回 404，错误 Key 返回 401；
  - 结构化日志只含路径类别、Key/账号 ID、状态码和耗时。
- 待用户在 Desktop 中验收：独立搜索（`alpha/search`）、记忆摘要和 thread goal。
