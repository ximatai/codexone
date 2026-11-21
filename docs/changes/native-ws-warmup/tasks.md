# 验收

记录合成预热对照、拒绝路径和待核对的真实上游边界。

- [x] 2026-11-21，macOS arm64，以 `002e3f2` 分别构建 Swift 和 Rust（该提交 Swift 源码及依赖与 v0.26.53 一致）。通过临时回环端口和数据库运行合成 Codex subscription WebSocket 上游。两边都通过省略或空数组 output。旧 Rust 拒绝 null、带响应归属的 metadata 和 WebSocket 耗时帧，Swift 三种均通过。这三个形状都能复现同一个 Rust 错误码。
- [x] 修正后，省略、null 和空数组均通过。连接元数据先于 created 原样下发，之后为 in_progress、completed；显式 null 在下游保留。预热缺失用量时账本为 `unknown/succeeded`，用量为空。随后在同一上游 socket 通过预热 ID 发起正式生成，再用上一正式响应 ID 续接，两次均为 `settled/succeeded`、完整用量。
- [x] 修正后，非空数组、畸形 output、生成 delta、带响应归属的 metadata、耗时帧及其他非生命周期事件仍拒绝，账本为 `unknown/failed`。每个客户端 create 恰好派发一次；错误帧无私有原因，日志只增加对应固定分类。测试使用合成头、内容及 ID 验证这些字段未写入日志。
- [x] Swift 对照还会接受带生成消息的非空 output 和畸形对象 output。Rust 按 P15 保留这两种形状的拒绝。
- [x] Rust WebSocket crate 全部 27 项测试、`verify_websocket.py` 及 `verify_client_protocol.py --expect-provider-eof` 通过。更新后的共享 WebSocket 用例在旧 Rust 的 null 预热复现失败，在 Swift 与修正后的 Rust 完整通过，覆盖单独预热模式、缺失用量、同连接续接、并发 lane 隔离、拒绝和断开后不重放。
- [ ] 核对真实订阅中触发拒绝的类别。

## 相关文档

[变更提案](proposal.md)
