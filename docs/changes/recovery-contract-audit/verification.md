# 恢复契约核实 · 2026-10-22

- 本机 Codex CLI 0.163.0，`python3 scripts/verify_client.py --binary .build/debug/codexone --retry-probe` 再次通过。独立临时 CODEX_HOME、空工作目录、只读 sandbox 与合成 Key；HTTP 在 response.created 后无终态，客户端 reconnect 创建第二次生成，账本分别 unknown、settled。未访问个人认证或真实上游，未消耗额度。
- 重新读取[官方 WS reconnect 契约](https://developers.openai.com/api/docs/guides/websocket-mode#reconnect-and-recover)：连接局部缓存关闭即丢失；store=false 时通过完整上下文新建 response。它不是重读原输出。
- [公开 API retrieve](https://developers.openai.com/api/reference/typescript/resources/responses/methods/retrieve)确实定义 GET /responses/{response_id} 及 stream/starting_after 读取；这是公开 API 能力，不证明当前订阅提供者支持、Codex CLI/Desktop 会调用或知道消费序号。不能把“存在标准 API”写成“目标客户端可用”。
- 当前网关仅 models、responses/create/compact、Images 入口，无已有输出读取路由。已有 response/item/opaque 归属只能授权引用，不能复原提供者连接缓存、证明客户端消费位置或避免客户端另发生成。

结论：缺少目标客户端可使用的“关联 ID → 当前权限验证 → 既有输出读取/消费位置”契约，C10 尚不成立。M5 维持未完成；不建设无人可读的重型正文库，不新增私有恢复端点，不自动重生成/合并/退款或释放原 unknown。下一步需要明确版本客户端读取轨迹与断线/重启/工具/图片行为，或明确采纳人工导出/新客户端等产品范围调整。用户已授权先推进不依赖此契约的 M6 安装发行准备，Desktop 与真实订阅继续保留缺口。
