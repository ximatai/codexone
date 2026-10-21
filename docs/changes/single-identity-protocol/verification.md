# M2 分切片验证

## HTTP JSON/SSE 与持久执行

2026-10-22，macOS arm64 / Swift 6.4 / Node 22.23.0 / 本机 Chrome。主 Agent 实现、复盘，提交前 `./scripts/verify.sh --backend` 完整通过（31 个 Swift 测试函数，端口/旧库参数案例另计）；其中真实进程/HTTP/SSE 合成上游验证标准/现有前缀、模型/认证、未授权模型/未知引用/background/内置工具发送前拒绝、函数调用结果归属及续接、SSE 终态/EOF、静默断开取消、绑定失败不暴露 ID、已知用量仍入账、后续发送停止及 readiness 降低。SIGTERM 正常退出并释放两个入口，日志中无合成 Key/请求头/正文/配置路径标记。

自我复盘修复：NIO 默认流水线辅助会在响应未完成时推迟读取，真实测试暴露静默断开无法取消，改由有界异步通道承担背压、关闭该辅助；ServiceLifecycle 关闭异步 listener 的预期取消不再变成非零退出。可信 usage 在对象分类/绑定前记录；部分字段只作已观察下界并保留 unknown。函数工具与输出类型严格分类，未支持图片/私有对象不直接透传；JSON 深度与 SSE 分片/累计有界。origin/凭证变化建立新命名空间，配置/计价摘要按结构稳定编码而不使用有歧义的拼接。

`cd web && npm run build` 和 `python3 scripts/verify_protocol.py --binary .build/debug/codexone --web-smoke` 通过。浏览器未拦截管理 API，UI 连接真实临时后端；1440×900 正常及存储失败状态、刷新操作通过，主 Agent 查看两张合成截图，位于忽略目录 artifacts。

范围：此记录只证明 HTTP 文本/客户端函数工具的合成闭环；不是完整 M2、Desktop、原生 WS/桥接、预热/压缩、真实订阅或生产反代验收。M1 Linux 验证仅适用于其独立快照，未冒充此切片的 Linux 结果。

协议依据：[官方 WebSocket 模式与恢复](https://developers.openai.com/api/docs/guides/websocket-mode)、[官方自定义 provider 配置](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers)。官方 API 文档不等于订阅后端或指定 Desktop 版本已经兼容。
