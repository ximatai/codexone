# 项目状态

公开能力范围、已知限制和后续方向的简明入口。

## 版本与能力

当前版本为 **[v0.26.3](https://github.com/ximatai/codexone/releases/tag/v0.26.3)**（2026-11-01），核心数据库 schema v10。镜像发布在 GHCR `ghcr.io/ximatai/codexone`（Linux amd64），附来源证明；也可以从源码构建。

项目是个人自托管网关：管理自己的 ChatGPT/Codex 订阅账号，为自己的多台设备和工具分别发放 Key。已实现账号授权/刷新与额度观察、Key 权限/轮换/归档/全部模型范围、本地限额和用量诊断、Responses HTTP/SSE/WS 与桥接、预热/压缩、原生图片生成/参考图编辑、同源管理面板、快照备份和维护迁移；v0.26.2 起提供设备码授权、可选局域网 HTTP 模式与网关自动重启。

当前开发分支新增账号重置卡列表、确认使用与默认关闭的到期前自动使用；源码 schema **v11**，须按[维护指南](docs/guide/backup-upgrade.md)停服备份迁移，v10 及更旧程序拒绝 v11。公开版本 v0.26.3 仍为 v10。

## 已知限制

- 单节点、单管理员；容器目标为 Linux amd64 Docker Engine。源码开发支持 Linux、macOS 与 Windows（WSL2）。
- 多账号选择机制已有实现，完整多账号路由仍需独立验收；用量和费用可为部分或未知，不用于对外结算或绝对封顶。
- 正文/图片恢复缓存尚未交付；不保证任意断线或重启后恢复已有输出，不自动重放可能已执行的请求。
- 内部协议可能变化。官方客户端标识与 OAuth ID 的使用可能违反提供者条款、触发风控或账号限制，详见[兼容与风险](docs/reference/compatibility.md)。
- v10 不能使用 v9 或更旧程序原库回退；升级、备份恢复与迁移须按[维护指南](docs/guide/backup-upgrade.md)执行。
- 发版验证在 GitHub Actions 的合成环境中运行；真实订阅、客户端组合与具体服务器容量仍需各自部署验证。

## 路线图

- [发行 CI 并行验证与缓存](docs/changes/release-ci-speed/proposal.md)的冷/热 dry-run、耗时和镜像交接验收。
- Node.js 26 与 GitHub Actions 大版本升级后的 Linux CI、开发容器和发行流程验收。
- 多账号路由与故障切换的完整兼容验收。
- [用量分析](docs/changes/usage-analytics/proposal.md)：模型/客户端分布及 CSV。
- [Key 自助查询](docs/changes/key-self-service/proposal.md)：只读、隔离的设备用量入口。
- 暗色模式与交互改进。
- 在可验证的客户端读取契约基础上评估有限恢复缓存。

仍有未完成验证的变更保留在[活动提案](docs/changes/README.md)，不因文档整理标为完成。

## 相关文档

[CHANGELOG](CHANGELOG.md) · [构建与验证](docs/development/verification.md) · [文档导航](docs/README.md)
