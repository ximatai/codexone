# 任务：中断后断开时续读上游终态

契约见 [proposal](proposal.md)。

- [x] 已转发中断的在途 turn 在下游断开后续读至终态或 10 秒。
- [x] 资源释放与运行时取消。
- [x] Desktop 常见 `x-codex-*` 头列为已知。
- [x] 合成测试与规范同步；完整 `verify.sh --backend`。
- [ ] Linux verification、部署与 Desktop 停止验收（主 Agent）。

本机验证与边界见 [verification](verification.md)。
