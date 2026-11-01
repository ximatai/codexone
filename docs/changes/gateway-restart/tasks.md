# 任务：网关自动重启

契约见 [proposal](proposal.md)。

- [ ] gateway 改为 `unless-stopped`，init-data 与一次性维护容器保持不重启。
- [ ] 安装验证覆盖 SIGKILL 自动恢复、stop 后保持停止、维护命令失败不重试、配置错误有界退避。
- [ ] 运维规范 O12 与 Linux 安装指南同步。
- [ ] 测试实例升级后确认策略生效且数据不变。

## 相关文档

[文档导航](../../README.md)
