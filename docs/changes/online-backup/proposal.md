# 在线定时备份与容器日志轮转

日期：2026-10-31。修改[运维](../../specs/operations.md) O04 备份流程与[维护操作](../../development/snapshot-maintenance.md)、[存储压力](../../development/storage-pressure.md)、部署模板。

## 问题

试运行实例没有任何定期备份。现有 `--backup` 需要实例锁，只能停服执行，不适合每日例行。数据库丢失意味着订阅账号需重新授权、Key 治理与全部账本丢失。另外部署模板未限制容器日志大小。

## 行为

### 在线定时备份

- Runtime 新增单一备份 owner：服务持实例锁运行时，按固定周期（默认每 24 小时，启动后首次在 10 分钟后）在 writer 之外用 SQLite Backup API 生成与 `--backup` 相同格式的完成 bundle（manifest 最后发布并同步、权限 0700/0600、含主密钥 key ID 依赖），写入独立挂载的备份目录（配置项 `CODEXONE_BACKUP_DIRECTORY`，绝对路径；未配置则不启用）。
- 分步复制、每步短暂让出，不长时间阻塞核心写；存储压力 degraded/blocked/unknown 时跳过本轮（与“暂停新备份”一致），记录跳过原因。
- 保留最近 7 份完成 bundle（命名常量），新 bundle 完成并验证后才删除最旧的；partial/中断目录在下次运行时清理，不计入保留。
- 生成后自检：完整性、摘要与 manifest 一致（等同 `--verify-backup` 的离线部分）；失败保留旧 bundle 并记录失败。
- 不改变 schema，不进入核心库写事务；备份失败不影响准入。

### 观测

- `/api/runtime/storage`（或现有系统接口）增加最近成功备份时间、最近失败时间与固定失败分类、保留份数。
- 备份目录总占用超过 5 GiB 或单份超过 768 MiB（接近 1 GiB 硬上限）时提醒 warning。
- 首页提醒新增 `backup_stale`：已启用备份但超过 36 小时无成功备份为 warning，超过 72 小时为 critical；未启用备份为 warning `backup_disabled`。

### 部署模板

- compose 增加备份卷（独立命名卷，挂载到 gateway 的备份目录），并设置 `CODEXONE_BACKUP_DIRECTORY`；文档说明需定期把备份与主密钥分别复制到其他机器，单机卷不防磁盘损坏。
- 各服务设置 json-file 日志轮转（`max-size: 10m`、`max-file: 5`）。

## 不做

- 异地上传、加密打包、可配置周期/保留数、备份浏览 UI。

## 验收

- 在线备份与服务并发：备份期间准入与结算不中断；生成的 bundle 可被 `--verify-backup` 通过并能 `--restore` 到新目标。
- 保留：第 8 份完成后删除最旧；新备份失败不删旧；partial 清理。
- 存储压力下跳过；备份目录不可写/空间不足时记录失败且服务正常。
- 提醒 36h/72h 边界、未启用提示；接口字段。
- compose 配置校验通过（日志轮转与备份卷）。
- 规范与运维文档同步；`verify.sh --backend`、`verify.sh --web --chrome`；主 Agent Linux verification（含在 Linux 容器内实际生成并恢复一次）。
