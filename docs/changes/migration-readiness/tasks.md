# 任务：迁移就绪

契约见 [proposal](proposal.md)。

- [ ] A：非原生客户端统一为 Codex CLI 标识（HTTP、compact、Images、控制、上游 WS 握手），并加入 `clientFingerprint` 配置。
- [ ] B：提供者在输出前明确拒绝时，结算为零用量、complete；同步用量规范。
- [ ] C：`dataConnections` 可配置（缺省 128）；上游连接期限与发送前重试；记录资源测量。
- [ ] 规范同步（协议、用量、运行限制），配置示例与文档。
- [ ] 定向测试与完整 `verify.sh --backend`。
- [ ] Linux verification（主 Agent）。
