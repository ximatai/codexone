# M2 分切片验证

## HTTP JSON/SSE 与持久执行

2026-10-22，macOS arm64 / Swift 6.4 / Node 22.23.0 / 本机 Chrome。主 Agent 实现、复盘，提交前 `./scripts/verify.sh --backend` 完整通过（31 个 Swift 测试函数，端口/旧库参数案例另计）；其中真实进程/HTTP/SSE 合成上游验证标准/现有前缀、模型/认证、未授权模型/未知引用/background/内置工具发送前拒绝、函数调用结果归属及续接、SSE 终态/EOF、静默断开取消、绑定失败不暴露 ID、已知用量仍入账、后续发送停止及 readiness 降低。SIGTERM 正常退出并释放两个入口，日志中无合成 Key/请求头/正文/配置路径标记。

自我复盘修复：NIO 默认流水线辅助会在响应未完成时推迟读取，真实测试暴露静默断开无法取消，改由有界异步通道承担背压、关闭该辅助；ServiceLifecycle 关闭异步 listener 的预期取消不再变成非零退出。可信 usage 在对象分类/绑定前记录；部分字段只作已观察下界并保留 unknown。函数工具与输出类型严格分类，未支持图片/私有对象不直接透传；JSON 深度与 SSE 分片/累计有界。origin/凭证变化建立新命名空间，配置/计价摘要按结构稳定编码而不使用有歧义的拼接。

`cd web && npm run build` 和 `python3 scripts/verify_protocol.py --binary .build/debug/codexone --web-smoke` 通过。浏览器未拦截管理 API，UI 连接真实临时后端；1440×900 正常及存储失败状态、刷新操作通过，主 Agent 查看两张合成截图，位于忽略目录 artifacts。

范围：此记录只证明 HTTP 文本/客户端函数工具的合成闭环；不是完整 M2、Desktop、原生 WS/桥接、预热/压缩、真实订阅或生产反代验收。M1 Linux 验证仅适用于其独立快照，未冒充此切片的 Linux 结果。

协议依据：[官方 WebSocket 模式与恢复](https://developers.openai.com/api/docs/guides/websocket-mode)、[官方自定义 provider 配置](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers)。官方 API 文档不等于订阅后端或指定 Desktop 版本已经兼容。

## HTTP 切片提交后 review 修复

提交 035adb8 后独立 subagent review 找到三项 P1：单 chunk 的后续解析错误吞掉此前事件、流式 part 绕过 annotations 检查、AHC 的请求 deadline 仅覆盖响应头。主 Agent 亲自改为逐字节识别并立即交付完整事件，终态后停止读取；流式/终态内容复用验证，拒绝非空 annotations、未支持嵌套字段和非空 logprobs；单调任务期限覆盖完整操作，超时取消并等待子任务退出。配置可将默认 120 秒缩短到 1—120 秒，并进入策略版本。

2026-10-22 macOS 完整后端验证通过（32 个 Swift 测试函数）；真实 socket 新增终态与无效 JSON/超限尾部同次写入、私有 file citation 被拒绝、持续有进展但无终态的 SSE 在 2 秒总期限终止并保存 unknown。已有取消、屏障失败、用量、SIGKILL 检查仍通过。

独立 Linux amd64 容器对 035adb8 的验证未通过：CRLF 分片测试返回零事件，后续索引越界使测试进程退出。测试前置计数已改为 require，避免失败后再次越界。e32696a 的逐事件重写仍在 Linux 返回零事件；进一步最小复现确认 Linux Foundation 的 components(separatedBy: "\n") 不拆开 CRLF，先将完整 CRLF 规范化为 LF 后再分行。修复快照的 Linux 结果须另行记录，不将旧快照失败写为通过。

2026-10-22：Linux amd64/Swift 6.4 本地容器对 388d90b 的完整后端验证通过，32 个 Swift 测试函数及全部进程/故障/socket 场景通过，容器正常退出且未 OOM。使用 M1 相同官方 Swift 镜像/本地依赖层、2 CPU/2500 MiB、单构建并发与模拟执行；不是远端 CI 或弱服务器验收。reviewer 对 e32696a 三项 P1 与 388d90b CRLF 修复复审通过，无新增阻塞问题。

## WS 默认串行 lane 与 HTTP 桥接

2026-10-22 macOS arm64/Swift 6.4：主 Agent 实现并自我复盘，完整后端统一验证通过（32 个 Swift 测试函数，加进程/socket/SIGKILL 脚本）。新增 Python 标准库 RFC6455 合成 fixture 实测：本地握手不连接上游、首 create 延迟建连、masked/fragmented 输入与 ping/pong、同 socket previous_response_id、排队默认 lane FIFO、两个前缀、HTTP JSON/SSE→WS、终态后立即 EOF 不丢用量、提前关闭 unknown、未支持控制不 dispatch、静默断开取消、DB 屏障失败不暴露 ID、SIGTERM 关闭尚未完成协议协商的原始 socket。

自我复盘：Bootstrap initializer 必须在协议配置后返回内部 future，不能等待握手完成再注册 TCP；补入协议协商前的 channel owner。上游 EOF 由单 reader 排空已收事件再通知消费端，避免 closeFuture 抢先清空终态。队列满时单 producer 有界等待并停止读取，拥塞超时后统一结束；不因普通突发超过四事件立即丢弃执行。HTTPS/WSS 代码启用系统证书及主机名校验，未接触真实上游，尚无真实 TLS/客户端验收。

范围：只验收默认串行 lane，当前拒绝命名 lane/预热，压缩尚未实现；HTTP 桥接每次新 socket，不保证 store=false 跨 HTTP 续接。无前端产品修改；此前管理概览真实浏览器联调记录仍只覆盖 HTTP 切片。此 WS 快照待提交后独立 review 与 Linux 验证。
