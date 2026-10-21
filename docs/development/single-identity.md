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

## WebSocket 首个切片

配置 `upstreamTransport: "websocket"`，base URL 仍用可信 HTTP(S) origin；握手路径为其 `/responses`，HTTPS 使用系统信任与主机名校验。原生下游支持两个前缀的 GET `/responses`，只允许默认串行 lane；当前拒绝 stream_id、generate:false 和未支持控制。原生连接在首个有效 create 后使用固定上游 socket；HTTP 桥接每执行新建 socket，不能由桥接成功推导 store=false 跨请求续接可用。无自动重连/重放。

`verify_websocket.py` 使用 Python 标准库实现有界合成 RFC6455 客户端/上游，纳入后端统一验证；验证帧 masking/分片/ping、延迟建连、同连接续接、FIFO、桥接 JSON/SSE、EOF/断开取消、DB 屏障失败和未完成握手关闭。原生命名 lane、预热、压缩与 Desktop 验收仍需后续切片。
