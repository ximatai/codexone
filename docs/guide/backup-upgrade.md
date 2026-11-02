# 备份恢复与升级回退

保留账号解密依赖和执行责任，避免把旧快照误当作安全回退。

## 前提

操作前阅读目标版本发布说明顶部的“升级注意”，保存当前不可变镜像引用、配置、完整 bundle 和对应的全部账号主密钥。备份和主密钥分开异地保管。

## 备份与恢复

Compose 默认使用独立 backups 卷，启动 10 分钟后首次备份，随后每轮结束等待 24 小时，保留 7 份通过自检的 bundle。同机卷不能防止主机或磁盘丢失，定期检查首页提醒并演练异地恢复。

离线维护先停服。`codexone --backup <new-absolute-bundle>` 导出一致性 bundle，`--verify-backup <absolute-bundle>` 检查完整性和解密依赖。恢复使用全新空数据目录和原密钥，执行 `--restore <absolute-bundle>` 后进入维护态；按[快照维护](../operations/snapshot-maintenance.md)核对缺失区间与审计基线，换发 Key、重新授权账号，再恢复接单。不要直接复制旧数据库覆盖在线库。

## 升级

在私有安装目录执行：

```sh
python3 compose-install.py stop
# 编辑 .env 为已核验的不可变镜像引用，保留原卷和 secrets
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py run --rm gateway --migrate
python3 compose-install.py up -d
python3 compose-install.py ps
```

当前 schema 为 v11；旧 v1—v10 必须显式停服迁移，迁移前自动生成的一致性数据库备份不能替代完整恢复 bundle。失败时保持停止并保留源库，不清卷、不覆盖主密钥。

## 回退

只有 schema、凭证信封、配置与 Key 策略均兼容并实际验证过的旧二进制才能使用原库回退。v10 及更旧二进制不能打开 v11。

每日 Token 版本即使沿用 schema v11，写入的 Key 策略也与 v0.26.5 等旧五字段版本不兼容：旧版读取/认证这些 Key 会失败。不支持将写入 Token 策略后的原库直接回退；把 null 改为数值或模型改为清单不能解决字段缺失，`--migrate` 也不会降级策略。优先前向修复；必须使用旧版时，先保存并验证当前完整 bundle，再用与目标旧版兼容的升级前 bundle 恢复到全新空目录，保留当前库供核对。没有兼容 bundle 时保持停服。具体步骤和其他版本限制见[Key 回退前提](key-governance.md#兼容回退前提)。

恢复旧快照会丢失新区间的本地记录，但不会撤销上游已执行请求。应先保存新库 bundle，按维护态流程披露缺失区间并核对；不得恢复旧余额、自动退款或重放未知请求。不要运行 `down -v`。

v11 同时包含空闲配额窗口预热设置/屏障/审计。恢复后预热默认关闭，窗口屏障保留，未知生成不自动重发；回退保留对应账本证据。

## 相关文档

[主密钥](../operations/master-key-maintenance.md) · [快照维护](../operations/snapshot-maintenance.md) · [版本规则](../development/releasing.md)
