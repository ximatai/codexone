# 发行与部署模板

提供 Linux amd64 OCI、Compose 初始化和 TLS 反代模板。

安装顺序、私有配置和镜像边界见[安装部署](../docs/guide/linux-installation.md)，升级恢复见[维护指南](../docs/guide/backup-upgrade.md)。GHCR 镜像首个版本发布后可用，Release 工作流的手动 dry-run 只生成验证归档，版本标签触发验证后的 GHCR 推送、来源证明与 GitHub Release；流程见[发版规则](../docs/development/releasing.md)。

## 相关文档

[版本与发布](../docs/development/releasing.md) · [运维规范](../docs/reference/specs/operations.md)
