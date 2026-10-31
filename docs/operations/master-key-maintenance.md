# 多版本主密钥与再加密

维护账号凭证主密钥的多版本、再加密与退役依赖。

## 前提

本流程是本机离线维护，先停服，使用可靠私有本地磁盘、当前二进制、原数据目录和独立保管的主密钥。没有远程认证/刷新、生成调用或 secret 删除功能。配置文件与备份放在源码 checkout 外；不要在命令行参数、环境值或日志中粘贴密钥材料。

## Keyring

`CODEXONE_ACCOUNT_MASTER_KEY_FILE` 继续接受原有 64 hex 单密钥文件，也接受私有 JSON keyring。文件须由进程用户持有、普通文件、无符号/硬链接、无组/其他权限，最大 8192 字节。root 只允许 `format`、`active`、`decryptOnly`：

```json
{
  "format": 1,
  "active": "<安全随机生成的64个hex字符>",
  "decryptOnly": ["<原主密钥的64个hex字符>"]
}
```

示例占位符必须替换为私下生成/保管的随机 32 字节材料，不能使用测试常量。一个 active、至多七个 decrypt-only，材料不得重复（含 hex 大小写变体）。所有版本都拒绝复用管理员 secret 或已提供的静态数据 Key 摘要。管理员凭证仍独立配置。keyring 描述/错误固定脱敏，key ID 为材料 SHA-256 前 16 字节，标识不是密钥。

v1 信封和 AAD 不变：新导入/重新授权/刷新只用 active，读取按信封 key ID 选择 active 或 decrypt-only，未知 ID/篡改/错误上下文拒绝。没有自动热加载；在私有配置处安全准备完整候选文件，停服切换，并保留原版本和旧密钥。正常账号池仍沿用本地可解密候选检查；缺失密钥的账号不能派发，不表示其他可用账号自动失效。退役检查对**全部**当前密文要求可解密。

## 再加密与中断续作

空库 schema v10；已有 v1—v9 先停服 `codexone --migrate`，保留 `.pre-v10-<id>.sqlite`。v8 防止旧 v7 二进制绕过再加密检查点，不能原地换回旧版本。先把新 active 和全部仍有引用的旧 decrypt-only 配置到私有 keyring，再执行：

```sh
codexone --key-status
codexone --reencrypt-credentials /private-backups/before-new-key
codexone --key-status
```

配置数据目录、独立管理员凭证和 keyring，与运行实例使用同一环境变量。新备份目录必须不存在且父目录已存在。命令先验证所有当前密文，持同一实例锁生成独立完成 bundle，再持久记录 job/backup/target key ID；在一次锁所有权下每页最多八个账号，以旧密文、identity/namespace、credential version 和 revision 做 CAS，密文替换与追加检查点同事务提交。全部账号硬上限 64，预留最多十条维护审计容量；审计总上限 1000，不自动裁剪。

不改变 credential version/revision、模式/授权/刷新 intent、执行账本和恢复基线。再加密不等于向提供者刷新凭证；原 refreshing 在正常重启后仍按既有规则转 auth_uncertain。完成前复核全部密文可解且只引用 active。新备份仍可能依赖旧 key，不能因为它是轮换命令生成就删除旧 key。

页内失败同时回滚该页密文和检查点，已提交页不撤销；SIGKILL 后可留下混合版本。普通服务拒绝未完成 job，不能跳过/清理检查点；保留全部密钥，查询并续作：

```sh
codexone --key-status
codexone --resume-reencryption
```

续作须使用原 job 的 target 作为 active，并保留解密当前混合版本所需旧 key。不能改 active 后把原 job 冒充另一轮；先完成，再开始新一轮。相同已完成 job 的续作幂等。未完成 job 禁止制作新完成备份和其他维护审计写入，避免消耗保留容量；原 pre-job bundle 保持独立可恢复。硬盘不可写时继续拒绝服务；页前空间预算、储备与水位见[存储压力](storage-pressure.md)，不能用再加密侵占关键收尾余量。

## 旧备份依赖与恢复演练

```sh
codexone --verify-backup /private-backups/before-new-key
```

只读验证完成 bundle 的权限、摘要、schema/来源与全部账号密文，manifest 的 requiredKeyIDs 是**实际信封引用的有序去重集合**，不是当前 active 或 keyring 全集。旧 v7/v8/v9 和当前 v10 完成 bundle 都可验证；显式恢复 v7/v8/v9 bundle 时，在保留原 bundle 的前提下将私有 staging 升到 v10，无需修改只读源。恢复仍进入[快照维护](snapshot-maintenance.md)，不绕过旧授权失效、未知执行和额度基线核对。

验证恢复时设置另一个全新私有数据目录，配置同一候选 keyring，运行 `--restore ABSOLUTE_BUNDLE`。恢复目标保留 restore ID/backup ID 作为来源证据；这只证明本地解密和维护恢复，不证明真实账号重新授权、无损切换或掉电。

## 退役检查

只有所有当前引用和所有保留副本都不再依赖旧 key、恢复演练通过，才可在私有 keyring 中移除它。使用**候选移除后的 keyring**，提供私有 0600 完整清单（目录为占位符；各上限 32，不输出路径）：

```json
{
  "format": 1,
  "inventoryComplete": true,
  "auditReference": "private-inventory-audit-1",
  "retainedBackups": ["/private-backups/retained-bundle"],
  "restoreDrills": ["/private-drills/restored-data"],
  "legacyDatabases": [],
  "legacyRestoreAuditReference": null
}
```

```sh
codexone --check-key-retirement /private-config/retained-inventory.json
```

命令验证全部当前密文、每个完成 bundle、每个演练目标的密文/恢复来源，要求每个 retained backup ID 都有匹配恢复记录，且演练目标离线。输出/追加审计仅含 key ID、backup/restore ID、原始备份 SHA-256 和非秘密审计引用；不写入路径/材料。没有任何自动删除或不可逆“允许删除”开关。

迁移前原始 v7/v8/v9 SQLite 备份列入 `legacyDatabases`，须为无 WAL/SHM/lock 的私有只读一致性备份，逐一校验摘要稳定、完整性及解密依赖；须额外提供 `legacyRestoreAuditReference`，关联操作者在独立副本上完成的迁移/恢复演练证据。工具**不自动证明该外部审计**。更早 raw schema 暂拒绝核对，不能据此退役旧 key；先在独立副本显式迁移、完成恢复演练，明确销毁旧格式副本后，再核对完整剩余清单。

`inventoryComplete` 是操作者对所有离线/异地/迁移前副本的责任声明；工具无法发现未列出的副本，也不能证明某个副本已销毁。仍保留旧 bundle/raw 副本时，缺失旧 key 会使检查失败；不能用删清单条目代替处理副本。若明确销毁旧备份，先核实新备份和恢复证据，再在外部审计记录销毁，最后更新完整清单重新检查。保留清单、审计证据和独立 secret 备份，避免只轮换线上密文就丢失历史恢复能力。

## 相关文档

[文档导航](../README.md)
