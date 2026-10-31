# 在线备份验证

日期：2026-10-31。平台：macOS arm64。仅本机合成 SQLite/管理 API/浏览器数据；未运行 Docker/Linux、部署、真实订阅或生成调用，未推送。STATUS.md 按执行授权保持不变。

## 覆盖与证据

- `onlineBackupCopiesAlongsideRealAdmissionAndSettlementAndRestores`：8 MiB 合成库，在 Backup API 已完成一批、下一批前保留 transfer 的窗口实际执行 20 次准入/完整结算，再继续复制；持锁服务不退出，离线备份仍被锁拒绝；在线 bundle 复用 verify 通过并恢复到全新目标，保留主密钥依赖，恢复账号为 requires_auth。
- `onlineBackupRetainsSevenOnlyAfterVerifiedPublicationAndCleansPartial`：第 8 份后删最旧，复制批次空间故障与实际破坏 SQLite 文件引发的自检失败均不删旧份；下轮清理 partial，重建 owner 从 manifest 恢复健康。
- `onlineBackupDirectoryFailuresDoNotAffectCoreAndConfigurationRejectsUnsafeDirectories`：相对路径、不存在、宽权限、无写权限、链接拒绝；运行时目录权限失败记录固定分类，核心仍能准入/结算，修复目录后可再备份。
- `onlineBackupSkipsAllNonNormalStorageAndCancelsWithoutPublishing`：degraded/blocked/unknown 均跳过，记录压力；取消复制不发布。空间水位与复制批次故障为内部注入，不填满宿主磁盘，不据此宣称 Linux ENOSPC 已通过。
- `backupAttentionUsesStrictAgeAndSizeBoundaries`：36h/72h 的恰好边界与后一秒、未启用、5 GiB/768 MiB 的恰好边界与后一字节。
- `backupStorageRouteReturnsSanitizedHealthWithAuthentication`：认证/no-store/固定健康字段，未认证拒绝，响应无路径或秘密。
- `onlineBackupSingleFlightDoesNotTouchUnmanagedBundles`：并发触发仅执行一次，不改手工目录。
- Runtime/配置测试：600 秒首次延迟、86400 秒周期常量、单 owner、取消与重复运行拒绝、备份目录须绝对且有核心数据目录。
- `check_backup_compose.py`：PyYAML 解析所有服务日志 10m × 5、两服务备份挂载、卷标识隔离、旧 manifest 派生与宿主污染拒绝；同步 Linux 安装验证的双卷/清理断言，未运行 Docker。
- 前端：新提醒解析/文案/链接、存储详情最近成功和保留份数；Chrome 1440×900、390×844 实际打开关闭详情，无横向溢出。截图位于忽略的 artifacts/online-backup；独立前端 subagent 的 P2“历史成功一律绿灯”已修复为 36h 新鲜度判断，无 P0/P1。

## 命令结果

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---|---|---|
| `swift test --disable-sandbox --skip-update -j 12 --no-parallel --filter 'onlineBackup\|backupAttention\|backupStorage\|backupSupervisor\|backupConfiguration\|snapshot\|attention'` | 0 | 93.97s（含首次构建） | 24 项通过，在线 bundle 校验/恢复与并发写入通过 |
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 1 | 494.84s | 格式/依赖边界/构建、277 项 Swift 与前段标准脚本通过；到 verify_admin 的旧“空提醒”断言失败 |
| 下列失败脚本及剩余 5 个入口（顺序运行） | 全部 0 | 合计 15.09s | 更新未配置备份时应返回 backup_disabled 的会话/Bearer 断言，并校验 disabled 存储 DTO；全部后端验证项最终通过 |
| `CODEXONE_WEB_TEST_PORT=14173 ./scripts/verify.sh --web --chrome` | 0 | 35.22s | lint/格式/类型、Vitest 116 项、生产构建、Chrome 15 项全部通过 |
| `python3 scripts/check_backup_compose.py` | 0 | 0.11s | YAML、双卷、日志轮转、安装隔离/旧 manifest 兼容通过 |
| `codexone --check-config` 的 7 类合成配置检查 | 检查器 0 | 1.04s | 正常/未启用退出 0；相对、不存在、宽权限、不可写、链接退出 78，输出无路径 |
| `python3 scripts/check_docs.py` | 0 | 0.04s | 209 份 Markdown、链接和变更材料通过 |

失败入口补验与尚未运行的后段（此前已通过的入口未重复）：

```sh
python3 scripts/verify_admin.py --binary .build/debug/codexone
python3 scripts/verify_admin_round2.py --binary .build/debug/codexone --probe .build/debug/ExecutionProbe
python3 scripts/verify_admin_assets.py --binary .build/debug/codexone
python3 scripts/verify_pool_config.py --binary .build/debug/codexone
python3 scripts/verify_migration_cutback.py --binary .build/debug/codexone
```

前端首次入口在新增返回类型的 TypeScript 检查失败（2.11s），修复后完整前端入口通过。定向 Chrome 首次选择器匹配两条链接，收紧为行首标签后通过；截图等待 Drawer 动画完成。默认测试端口被占用，新增仅测试使用的可选端口变量，未结束占用端口的其他进程。

初次 SwiftPM 完整历史下载过慢，中止准备后用与锁文件 revision 一致的公开上游浅层本地镜像完成构建；本地配置与缓存均在忽略目录，Package.resolved 未改。镜像引发的 SwiftPM identity 警告不影响本次构建；不作为 Linux 构建证据。测试日志/截图仅为合成资料，记录文件中本机路径已脱敏。

无 schema 变化、无部署/真实调用或 push/PR。没有待决定的业务边界；Linux 实际文件系统、只读挂载、真实 ENOSPC、10 分钟定时触发与容器日志配置仍待主 Agent 验收。

## 主 Agent 的 Linux 出口

1. 在 Linux amd64 构建并运行现有 verification target，以及安装验证；不得以本机结果代替 Linux 文件权限、WAL 和卷初始化证据。
2. 新建隔离的合成安装（新 project/data/backups 卷与合成 secrets，不接真实上游）。用受控 launcher 检查 Compose config 和容器 LogConfig，确认 backups 为 0700、运行 UID/GID 所有，gateway 的备份目录可写。启动后等待至少 10 分钟，认证读取 storage.backup，确认 retainedCount=1、lastSuccessUnixSeconds 与 normal。复制期间的实际准入/结算与失败路径由 Linux Swift 测试覆盖。
3. 保留完成目录名，停源 gateway，再通过受控 launcher 运行 `gateway --verify-backup /var/backups/codexone/<完成目录>`。另建全新合成目标安装，保留同一合成主密钥，将源备份卷只读挂载到目标的 `/source-backups`，运行 `gateway --restore /source-backups/<完成目录>`；目标 data 必须为空且归属正确。执行 `--maintenance-status`，核对 backup ID、restored_unreconciled/冻结语义与源 bundle 未改动；不直接开启旧 Key/账号或恢复旧余额。
4. 在显式隔离 Linux tmpfs 上补实际 ENOSPC/只读挂载与关闭中断验证，确认旧 7 份不被删、核心服务不因备份失败退出；按安装标识清理本次合成容器和两个卷，不触碰其他安装。
