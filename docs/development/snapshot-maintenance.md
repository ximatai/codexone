# 核心备份、旧快照恢复与审计基线

所有操作均为本机离线维护；与服务/迁移使用相同实例锁，先停服。需要当前二进制、可靠本地磁盘和独立保管的账号主密钥。核心备份包含账号密文、Key 验证材料和账本，仍属私有资料，不含 M5 正文缓存。权限依据是操作系统私有文件所有权；不要把这些命令开放为无认证远程 shell。

## 备份与来源

配置 `CODEXONE_DATA_DIRECTORY` 指向现有源数据目录；包含账号时还须设置其原 `CODEXONE_ACCOUNT_MASTER_KEY_FILE`。以下目录均为占位示例，应放在源码 checkout 外，备份目的目录必须不存在且父目录已存在：

```sh
codexone --backup /private-backups/new-bundle
```

命令通过 SQLite Backup API 导出含 WAL 已提交内容的一致性快照，保留 intent 真相；不先把它们改为 settled/unknown。只读验证所有账号密文可由独立主密钥解开，输出 manifest 的备份 ID、快照时间、来源 generation、v8 schema、SHA-256/字节数和所需 key ID，不输出路径/凭证。多版本 keyring 时记录实际密文 key ID 集合，见[主密钥维护](master-key-maintenance.md)。

bundle 为 0700，snapshot.sqlite、snapshot.sqlite.lock、manifest.json 为 0600。manifest 最后发布并同步文件/目录；缺 manifest 或只有 partial 不算完成备份。单核心快照硬上限 1 GiB；审计记录硬上限 1000，达到容量时拒绝新增维护写入，不删除旧责任。保留备份对应的主密钥，manifest 的 key ID 不能代替密钥。SHA-256 用于完整性核对，不能证明一个不可信备份的来源；不要导入未知来源的 bundle。

旧 v1—v7 必须先按升级流程显式迁移至 v8（迁移前生成 .pre-v8 备份），再制作当前 bundle。已有 v7 完成 bundle 仍可验证并显式恢复，staging 升至 v8，源 bundle 保持不变。v8 二进制普通启动拒绝旧 schema；旧二进制也会拒绝 v8，避免忽略恢复门禁。迁移前单文件备份是升级证据，不是本流程的完成 bundle。

## 恢复到新目标

保留源数据、源服务配置和独立备份；为新目标设置 `CODEXONE_DATA_DIRECTORY`，目录可以不存在或仅为空的 0700 目录，不能已有数据库/侧车或其他资料。提供原主密钥后执行：

```sh
codexone --restore /private-backups/new-bundle
codexone --maintenance-status
```

可只读挂载 bundle。命令验证文件所有权/权限/无链接、manifest/schema/摘要/完整性/外键、来源 generation 和每份账号密文，再持目标实例锁。先同步目标目录的父目录，再在复制前持久写入 restore-pending，待 staging 库完成维护事务、同步并发布后才清除。中断目标拒绝普通启动；保留原备份，改用新的空目标重试，不手动删除 barrier 冒充恢复成功，也不覆盖已有服务。快照校验失败不会发布目标数据库。

输出 `restored_unreconciled`、restore ID、backup ID、snapshot/restored 时间和最早冻结截止时间。restored 时间在复制及源摘要复核完成后记录；发布和人工核对期间仍须保持源实例停服。核对须覆盖快照时刻直至首次审计时刻，不能把复制完成时间当成完整性证明。该区间的执行可能完全缺失；这是风险区间披露，不是已证明的完整执行列表，也不代表每个缺失执行都没收费。快照内 intent 转为 unknown，已有 unknown 不退款；历史账本保留。所有旧对象绑定删除，不承诺远端连接上下文仍存在。

恢复的所有 Key 被禁用且旧验证材料永久替换；再次启用旧元数据也不会复活旧秘密，须显式换发 Key。所有订阅账号进入 requires_auth，不自动刷新旧快照中的旋转凭证；须重新授权，避免旧/新实例无协调刷新同一凭证。管理员凭证、模型/profile、主密钥属于外部配置，另行保管和配置，不从 DB 猜测。

恢复库必须使用 `managedKeys: true` 的单上游配置或账号池配置；旧静态单身份配置会在监听前明确拒绝启动。保留原模型/profile，按[托管 Key](key-governance.md)配置管理员凭证，并经认证管理入口换发新 Key。

可以启动新实例进行管理、查账和发放新 Key，但 ready=503，生成在持久准入前明确 503 maintenance_required；管理认证/CSRF不变。新 Key 在维护态或冻结期也不能生成。`--maintenance-status` / reconcile 都是离线命令，查询/核对前先停服。

## 显式审计与冻结旧窗口

根据源服务/提供者账单和私有日志核对缺失区间。仅凭快照无法知道缺失执行的真实个数或费用。用私有 0600 JSON 文件提交如下字段（数值为合成示例，restore ID 须从实际报告取得）：

```json
{
  "restoreID": "00000000-0000-0000-0000-000000000001",
  "expectedRevision": 0,
  "auditReference": "external-audit-ticket-1",
  "missingUnresolvedRequests": 2,
  "missingUnresolvedMicros": 1000000,
  "freezeUntilUnixSeconds": 2000073600
}
```

```sh
codexone --reconcile-restored /private-config/baseline.json
codexone --maintenance-status
```

- auditReference 仅为非秘密外部审计编号（1—128 ASCII 字母/数字/点/短横线/下划线）；不得填写正文、凭证、服务器地址或个人路径。
- 首次核对的截止时间至少是核对当日的下一个 UTC 日边界（也不得早于恢复日的下一日），并继承前次恢复的冻结下限；已选冻结期不能缩短。受影响旧日窗口不再准入，新日窗口才授予新 Key 的新配额。不会恢复旧余额或抹去原账本计数。
- 数量/金额是缺失且尚未核清执行的**聚合全局占用**，不是虚构的每 Key/账号归属。它与快照内 unknown 的占用叠加，跨窗口持续约束总准入容量。旧 Key 已失效，新发 Key 额度是显式新授予，无法把丢失统计伪装成精确的原 Key 用量。管理用量查询仍显示快照内已知行；额外缺失占用必须同时查看维护报告。
- 第一次核对不能低于快照继承的缺失占用；确认零也必须明确填写并审计，系统没有默认零。未能核实的风险必须保守预留，足以占满容量时继续拒绝新工作。
- 首次 expectedRevision=0；以后取得新外部证据，可用报告中的 baselineRevision 作 expectedRevision，提交新的审计编号及**当前总缺失占用**。CAS 防旧请求覆盖新核对，相同请求重试幂等；每次修订追加维护审计，不删除历史，也不修改快照内已存在的 unknown。没有自动过期、自动退款或自动重执行。

核对后仍可显示 frozen；只有时钟到达冻结截止且存储/账号/授权等其他条件满足才 ready。首次核对若跨 UTC 午夜，重新查询 status 取得当前冻结下限；后续基线修订不会自动延长冻结。测试通过移动临时合成库的时间夹具验证新窗口，产品没有绕过时钟的开关。核心状态 schema v8 的不兼容二进制不得原地回滚；同 schema 二进制回退仍须兼容性证据，恢复旧快照必须重新走本流程。

## Compose 操作

沿用 [安装入口](linux-installation.md)，源安装先 `python3 compose-install.py stop`。在真实 Linux 上准备由运行 UID 拥有的私有备份父目录，以 `run --rm --volume /private-backups:/backup gateway --backup /backup/new-bundle` 挂载到受控 launcher；不要使用 macOS 共享盘证明实例锁或持久性。

恢复使用另一个全新私有安装/project/data 卷。按 init-install.py 生成独立配置和管理员秘密，私下保留原模型/profile，并把原账号主密钥安全安装到新 secrets/master（不要沿用初始化随机生成的新 master 解密旧库）。先 `run --rm gateway --check-config` 初始化空 data 卷，再只读挂载备份执行 `run --rm --volume /private-backups:/backup:ro gateway --restore /backup/new-bundle`。后续 status/reconcile 也通过同一受控 launcher，基线文件只读挂载到私有位置。不要修改已有安装的 volume 名去绕过 launcher，也不要删除旧卷。

此流程不会切换域名/路由、导入旧服务账号或授权实际生成；这些操作仍须按授权边界独立演练。Desktop、真实订阅兼容、M5、主密钥多版本轮换、低磁盘分级保护和目标宿主容量的状态见 [STATUS](../../STATUS.md)。

空间预算和部分失败边界见[存储压力](storage-pressure.md)；不能通过备份耗尽核心安全余量。

## 合成验证入口

```sh
swift test --no-parallel --filter SnapshotMaintenance
python3 scripts/verify_snapshot_restore.py --binary .build/debug/codexone
```

Python 场景覆盖真实 CLI/SQLite、锁冲突、快照后缺失执行、重启维护门禁、旧授权失效、错误基线、冻结与新窗口、只读备份源、损坏/部分/链接/权限拒绝，以及实际 SIGKILL 恢复屏障。全部使用临时合成资料；不代替掉电或真实旧服务切换验证。
