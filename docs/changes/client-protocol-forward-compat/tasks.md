# 任务：客户端协议前向兼容与原生 WebSocket 中断

契约见 [proposal](proposal.md)。

- [x] `response.interrupt` 转发与本地 failed；终态后确认仍转发。
- [x] 未知 WS 消息绑定后转发、绑定前与类生成成员拒绝、限速。
- [x] 未准入生成兜底：关闭连接并记 unknown。
- [x] `x-codex-*` 前缀头转发与上限。
- [x] 未知协议结构化日志。
- [x] 同步协议规范；定向测试与完整 `verify.sh --backend`。
- [ ] Linux verification、部署与 Desktop 停止/中途追加验收（主 Agent）。

验证证据与完整改动文件清单见 [verification](verification.md)。
