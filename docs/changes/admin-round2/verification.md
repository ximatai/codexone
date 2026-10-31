# 第二轮管理后端验证

日期：2026-10-31。平台：macOS arm64；全部临时合成数据与loopback上游，无真实账号/生成调用。前端、Docker/Linux及部署不在本次执行范围。

## 已验证边界

- 定向Swift测试：按日与账本合计对账（失败分类、缓存token、费用、Key/模型筛选、空数据、1/31天与非法边界）、非空nearest-rank P95与分页无关合计；原生Images缺失指标保持不可用。
- 10万attempts：日序列/筛选合计仍在既有单reader预算内返回，EXPLAIN命中attempts_created及新的intent部分索引；进行中行数受LIMIT限制。
- 进行中：真实流式执行出现、首事件运行时观测、安全字段白名单、最终化后消失；已派发途中设置到期仍可继续接收上游事件。
- 显示名：真实管理HTTP授权、非法字符/长度、CAS冲突、模式变更保留、重启保留、清除。迁移沿用v1—v8备份及intent/刷新责任恢复测试。
- Key到期：到期前认证、到期后401 api_key_expired且无新attempt；持久准入复核、已派发结算不受影响、清除/延长及重启持久化。
- 从基线ab971dc在独立临时源码目录构建真实v8 codexone（禁自动解析/更新，仅使用本机依赖副本）；正向启动产生v8库。新二进制拒绝未迁移v8；离线migrate生成0600 pre-v9一致性备份后升v9；旧v8二进制拒绝v9，拒绝前后核心数据库SHA-256相同。源备份保持v8，无partial发布。

## 验证入口与结果

| 验证 | 退出码 / 耗时 | 关键行 |
|---|---|---|
| 完整 `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 / 508.03秒 | 四批Swift测试35+43+3+154=235通过；全部后端Python场景通过，末行synthetic independent legacy backup/drain与settled/unknown切回通过 |
| 最终 `swift test --disable-sandbox -j 12 --filter 'round2|nativeImageUsage'` | 0 / 18.92秒 | 8 tests passed；10万条含非空首事件的合计/P95与按日查询通过（该测试含造数1.086秒） |
| 最终 `verify_admin.py` | 0 / 9.14秒 | real management sessions与account production assembly PASS；含真实在途观测、已派发后到期继续返回、结束消失 |
| 最终 `verify_admin_round2.py`（含真实v8二进制） | 0 / 4.17秒 | display-name HTTP与actual v8 binary startup control / migration / rejection PASS |
| 最终 `swift format lint --strict --recursive Sources Tests Package.swift` | 0 / 1.35秒 | 无lint诊断 |
| 最终 `python3 scripts/check_docs.py` | 0 / 0.05秒 | PASS: 180 Markdown documents |

完整入口首次因Clang写入沙箱外的默认模块缓存退出1（5.09秒），尚未执行测试；将CLANG_MODULE_CACHE_PATH及SWIFTPM_MODULECACHE_OVERRIDE指向允许的临时缓存后完整通过。未改Package或权限。完整套件后复核修正显示名编辑的刷新完成revision预留与到期竞态错误优先级，并补非法revision边界；以上最终定向及HTTP复测覆盖最终代码，没有重复完整套件。

定向入口：

```sh
swift test --disable-sandbox -j 12 --filter 'round2|legacyExplicitMigration|usage'
python3 scripts/verify_admin.py --binary .build/debug/codexone
python3 scripts/verify_admin_round2.py --binary .build/debug/codexone --probe .build/debug/ExecutionProbe --previous-binary /private-builds/v8/codexone
```

最后一项previous-binary是占位路径，必须提供真实v8二进制；无该参数仍检查账号HTTP。完整后端入口包含两份管理HTTP脚本，旧二进制检查另行显式运行。旧bundle恢复/再加密/权限/部分失败沿用完整后端套件。

## v9部署步骤

1. 暂停入口并有界收敛，停服；保留旧二进制、私有配置与原账号主密钥，确认可用磁盘和独立备份空间。
2. 在原私有CODEXONE_DATA_DIRECTORY设置下，以新二进制运行 `codexone --migrate`；共享实例锁、校验源库、先完成同目录私有 `core.sqlite.pre-v9-<id>.sqlite`（SQLite Backup API、一致性/同步），再事务新增display_name与intent部分索引并更新user_version=9。普通启动不替代迁移。
3. 保留原备份及全部解密依赖；新二进制启动恢复intent/刷新责任，检查管理认证、显示名编辑与Key到期后再放行。旧v7/v8完成bundle恢复只升级私有staging，不修改源bundle。
4. 不允许v8原地回退v9。需要旧快照恢复时必须走维护/缺失区间/授权失效/基线核对流程，不改user_version、不覆盖新责任。CI/安装脚本将旧v8 peer作为不兼容控制；尚无受信旧v9兼容peer，不宣称同schema回退已验证。

API方法/参数/字段见[管理规范](../../specs/control-plane.md)，取舍见[proposal](proposal.md)。运行时首事件状态在上下文结束后可能未知（null/缺省），不是恢复或结算依据；计时仅新记录可用。完整Linux检查与实际部署交主Agent，本次未运行。

## 改动文件

- `.github/workflows/`：`candidate.yml`。
- `Sources/CodexOneAdapters/ControlPlane/`：`AccountAdminAPI.swift`、`KeyAdminAPI.swift`、`UsageAdminAPI.swift`。
- `Sources/CodexOneAdapters/Downstream/`：`ProtocolFailure.swift`。
- `Sources/CodexOneAdapters/Persistence/`：`SQLiteAccountGovernance.swift`、`SQLiteConnection.swift`、`SQLiteExecutionStore.swift`、`SQLiteKeyGovernance.swift`、`SQLiteSnapshotMaintenance.swift`、`SQLiteUsageQueries.swift`、`SQLiteUsageReader.swift`。
- `Sources/CodexOneAdapters/Upstream/`：`ExecutionObservation.swift`。
- `Sources/CodexOneCore/Application/Execution/`：`ExecutionCoordinator.swift`、`ExecutionStore.swift`。
- `Sources/CodexOneCore/Application/Identity/`：`AccountGovernance.swift`、`KeyGovernance.swift`。
- `Sources/CodexOneCore/Application/Usage/`：`UsageQueries.swift`。
- `Tests/CodexOneAdaptersTests/`：`AccountDispatchTests.swift`、`AccountGovernanceTests.swift`、`ExecutionStoreTests.swift`、`ImageAdmissionTests.swift`、`KeyGovernanceTests.swift`、`KeyMaintenanceTests.swift`、`ObservationMigrationSupport.swift`、`SnapshotMaintenanceTests.swift`、`UsageQueryTests.swift`。
- `Tests/CodexOneRuntimeTests/`：`AccountObservationTests.swift`。
- `deploy/`：`Dockerfile`。
- `docs/changes/admin-round2/`：`proposal.md`、`tasks.md`、`verification.md`。
- `docs/development/`：`account-credentials.md`、`key-governance.md`、`linux-installation.md`、`master-key-maintenance.md`、`migration-cutback.md`、`snapshot-maintenance.md`。
- `docs/specs/`：`control-plane.md`、`identity.md`、`operations.md`、`usage.md`。
- `scripts/`：`verify.sh`、`verify_accounts.py`、`verify_admin.py`、`verify_admin_round2.py`、`verify_installation.py`、`verify_keys.py`、`verify_snapshot_restore.py`、`verify_storage_pressure.py`。
