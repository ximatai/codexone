# 任务：上游 WebSocket 空闲关闭同步关闭下游

契约见 [proposal](proposal.md)。

- [x] 上游空闲关闭时以 1000 关闭下游，释放连接与预留；在途 turn 维持现有最终化。
- [x] 关闭与新请求竞争时 dispatch 前拒绝。
- [x] 合成测试：空闲关闭、在途关闭、多 lane、竞争；单身份与账号池。
- [x] `include` 含 `output.encrypted_content` 透传回归测试。
- [x] 同步协议规范。
- [x] 完整 `verify.sh --backend`。
- [x] Linux verification。
- [ ] 部署后观察（需另行授权，由主 Agent 承接）。
