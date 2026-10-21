# 单身份配置与合成验证

全局进度和可运行入口见 [STATUS](../../STATUS.md)，协议与兼容目标见 [protocol](../specs/protocol.md)。

## 本地配置

`CODEXONE_IDENTITY_CONFIG` 指向单身份 JSON 文件，必须同时配置 `CODEXONE_DATA_DIRECTORY`。两个路径均为绝对路径；配置文件必须为当前用户拥有、其他用户不可读写的常规文件，不接受符号链接，最多 64 KiB。`--check-config` 先校验配置和外部运行时凭证，但不建库、不监听、不调用上游；输出仅包含安全的监听参数。

结构示例见 [合成配置](../examples/single-identity.synthetic.json)。该样例的 Key 是公开的 `synthetic-client-token-for-local-tests`，仅用于本地测试，所有价格与身份均为合成值。测试脚本自动创建私有临时配置、上游和数据库，不读取个人客户端配置。

| 字段 | 含义 |
|---|---|
| principal / keyID | 稳定主体与当前 Key 的非秘密标识 |
| keySHA256 | 高熵 Bearer Key 的 SHA-256 小写十六进制；文件不存原始客户端 Key |
| namespace / identity | 可信配置的提供者命名空间前缀与身份标识 |
| models | 明确模型 ID 与每百万输入/输出 token 的估算价格（微单位），用于本地治理，不代表订阅余额 |
| models[].catalog | 可选 displayName（1—128 UTF-8 字节）、description（≤1024 字节）、contextWindow（4096—131072，默认 32768）、reasoningEfforts（不重复的已知枚举，≤8）及其中的 defaultReasoningEffort；Codex 目录还需非空 baseInstructions 权威指导，容量与替换语义见下；不改变价格指纹 |
| reservedMicros | 单执行运营预留，不声称是真实最大消耗 |
| upstreamTransport | 可选 http（默认）或 websocket；后者同时启用原生 WS 与 HTTP→WS 桥接 |
| upstreamBaseURL | 字面 loopback HTTP 合成上游，或固定可信订阅 origin/path；不跟随重定向 |
| executionTimeoutSeconds | 可选 1—120 秒，默认 120；覆盖发送、响应体消费、屏障及输出，超时不重发，已有证据仍结算 |
| upstreamTokenFile | 可选独立运行时访问凭证文件；与配置同样校验 owner/权限/类型，最多 16 KiB，不写入核心库或日志 |

运行时注入只读取短期访问凭证，不保存/刷新授权；账号生命周期与持久凭证加密遵守身份规范。无法验证新旧凭证等价时，origin/凭证变化使用新命名空间，旧对象不能自由续接或跨身份试探；Key 轮换不改变主体隔离。配置/计价版本使用稳定摘要随准入记录，摘要不含原始凭证。

## 验证职责

根目录 `./scripts/verify.sh --backend` 包含 `verify_protocol.py` 的真实进程与 HTTP/SSE socket 合成测试。它验证路由/认证、未支持控制在发送前拒绝、函数结果归属、ID 屏障、终态/部分/缺失用量、EOF、静默上游取消、DB 写入失败、readiness 和关闭释放；不表示真实账号或 Desktop 兼容通过。

浏览器联调在先执行 `cd web && npm run build` 后，从根目录运行：

```sh
python3 scripts/verify_protocol.py --binary .build/debug/codexone --web-smoke
```

使用本机 Chrome 的独立临时上下文，构建后的 UI 连接真实临时网关管理 API，验证正常、存储失败及刷新，并将合成桌面截图放入被 Git 忽略的 `artifacts/single-identity-ui/`。这只是验证用静态服务器，不属于发行 Web 服务。

## WebSocket 传输

配置 `upstreamTransport: "websocket"`，base URL 仍用可信 HTTP(S) origin；握手路径为其 `/responses`，HTTPS 使用系统信任与主机名校验。原生下游支持两个前缀的 GET `/responses`，支持默认 lane 与最多 32 个命名 lane，同 lane FIFO、最多 16 个跨 lane 在途 turn；generate:false 作为独立 warmup 执行，未支持控制仍拒绝。原生连接在首个有效 create 后使用固定上游 socket；HTTP 桥接每执行新建 socket，不能由桥接成功推导 store=false 跨请求续接可用。无自动重连/重放。

`verify_websocket.py` 使用 Python 标准库实现有界合成 RFC6455 客户端/上游，纳入后端统一验证；验证帧 masking/分片/ping、延迟建连、同连接续接、FIFO、桥接 JSON/SSE、EOF/断开取消、DB 屏障失败和未完成握手关闭。预热/压缩已有合成验证，Desktop 实际兼容仍需单独验收。

下游提供 permessage-deflate 等扩展提议时，网关不协商扩展，保持普通无压缩帧；RSV 位仍拒绝。提议本身不导致握手失败。可选实际 CLI 脚本的 `--transport http|bridge|websocket` 分别检查客户端 HTTP/上游 HTTP、客户端 HTTP/上游 WS、客户端原生 WS；上游连接数量及执行记录用于防止把 HTTP 回退误算原生成功。

## 上下文与实际 CLI 检查

`verify_context.py` 已纳入统一后端验证：加密推理、独立 compact 及完整输出窗口续接、命名空间/custom 客户端工具、伪造/跨主体/变更身份引用发送前拒绝；DB/WAL 只留上下文指纹。warmup 的无用量终态仍 unknown，执行模式随 admission JSON 保存，旧记录缺失模式按 generation。

可选实际客户端检查（本机需安装 Codex CLI，CI 不因此依赖个人客户端）：

```sh
python3 scripts/verify_client.py --binary .build/debug/codexone
```

脚本创建私有临时客户端目录与空工作目录，在只读 sandbox 下使用合成上游，并显式关闭未支持的内置 web_search。客户端仅执行 `/bin/sh` 的固定 printf，不用登录 shell，网关不执行工具。此脚本验证 HTTP/SSE 文本、函数往返及加密推理回传；不代表 Desktop、真实订阅或所有客户端版本通过，不修改个人配置。

CLI 0.163.0 接入模型目录须在临时配置显式设置 `[features].api_key_model_discovery = true`，并在 provider 中设置同 origin 的 `model_catalog_url = "http://127.0.0.1:端口/v1/models"`。所有有效模型须显式配置 `catalog.baseInstructions`（非空，≤32768 UTF-8 字节），它会成为权威基础指导并替换客户端默认指导，须针对目标模型/版本维护；网关不生成默认提示。整个私有配置文件仍限 64 KiB，多模型长 profile 可能触及总容量。未配置完整 profile 时不返回 Codex models，带 client_version 的目录请求返回 503；这不能阻止客户端自己 fallback。验证脚本要求无 metadata fallback，且合成上游 developer 输入包含所配指导。

同脚本加 `--retry-probe`，验证 response.created 后 EOF 引起 CLI 第二次生成、原执行仍 unknown。它不是恢复已有输出；具体依据和未决客户端读取契约见[恢复证据](../evidence/client-recovery.md)。

加 `--compact-v2`，显式配置所选 CLI 的 remote_compaction=v2，并仅在临时测试配置中将自动压缩阈值设为 1，验证工具结果后的真实 compaction_trigger、压缩项与后续输入。可分别与三种 `--transport` 组合；要求恰好一次 compact、完整指纹绑定、无本地标签向上游透传、模式/用量及连接数量正确。阈值和合成零压缩用量只用于可控 fixture，不是生产配置或真实免费假设。无凭证 `verify_compaction_stream.py` 已纳入后端统一检查，覆盖 JSON/SSE/原生 WS、缺失/重复/不一致窗口、部分 EOF、混用控制、跨主体与 DB 屏障失败。

加 `--without-profile` 验证缺 profile 的目录失败可能使 CLI fallback 后仍生成；这项成功表示如实观察降级，不表示该配置通过 Codex 目录验收。

完整 profile 配置下，模型目录同时提供 OpenAI `data` 和 Codex `models`，来自同一白名单。当前切片明确声明仅文本、不支持内置搜索，目录元数据不授予额外权限。目录兼容性需与具体客户端分别验证，不能由 JSON 类型正确推导 Desktop 已通过。
