# 任务：网关自动重启

契约见 [proposal](proposal.md)。

- [x] gateway 改为 `unless-stopped`，init-data 与一次性维护容器保持不重启。
- [x] 安装验证覆盖 SIGKILL 自动恢复、stop 后保持停止、维护命令失败不重试、配置错误有界退避。
- [x] 运维规范 O12 与 Linux 安装指南同步。
- [ ] 测试实例升级后确认策略生效且数据不变。

前 3 项为实现与验证脚本交付；真实 Docker 场景由 Release 工作流的 `Verify actual private installation` 在 Linux amd64 执行，本地未构建镜像或运行这些场景。无账号合成安装按原状态恢复 ready 503，不把自动拉起等同可接单。

## 相关文档

[文档导航](../../README.md)
