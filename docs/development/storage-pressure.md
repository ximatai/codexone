# 存储压力与运行观测

适用于可靠本地文件系统上的单进程核心库，不支持网络共享卷。空间保护不替代磁盘/文件系统正确同步，也不保证其他进程抢占全部空间、inode 耗尽或硬件失信时仍能结算。失败仍依赖已持久 intent 恢复，不自动退款或重放生成。

## 分级与预留

服务持实例锁拥有 `core.sqlite.settlement-reserve`：私有 0600、当前进程用户、普通文件且无链接，实际写入并同步，验证格式标识和物理分配，拒绝接管未知非空文件或用 sparse 文件冒充。目标 64 MiB，文件不进入核心 bundle；停服后仍保留，不能把它当可选缓存手动删除。下列为预防性默认值，尚不是 O14 弱服务器容量承诺：

| 观察条件 | 状态与动作 |
|---|---|
| 可用空间至少 256 MiB，WAL 小于 64 MiB，储备完整 | normal，允许普通工作 |
| 可用空间低于 256 MiB，或 WAL 达 64 MiB | degraded，暂停用量报表、新普通管理写、被动额度观察及拒绝诊断写；新执行仍须通过准入检查 |
| 可用空间低于 128 MiB，WAL 达 128 MiB，或储备不完整 | blocked，拒绝新生成 intent 和新刷新 intent，ready=503，live 不受容量水位影响 |
| 无法取得可靠可用空间/文件证据 | unknown，关闭准入和可选工作，不仅凭统计失败冒充数据库损坏 |

从 blocked/unknown 恢复及启动开放时，须储备完整、可用空间至少 192 MiB、WAL 不超过 32 MiB；恢复到 192—256 MiB 仍属 degraded。实际容量采用可用给运行用户的 `f_bavail`，不把管理员保留块当可用空间。水位不改变已消耗配额、unknown 或冻结基线。

每次准入/写入在串行 writer 队列复核；排队时看到 ready 不算预先获得许可。已有绑定、最终结算、刷新结果收尾、启动恢复及必要模型健康配置可以使用储备；低空间按最多 8 MiB 分段释放，并同步文件。Key 禁用、账号 drain/禁用等真正收紧权限的操作仍可提交；新授权、启用、轮换和普通策略更新退让。最终化独立 16 个队列位置和 16 个 ticket 不变，不被普通命令占用。

只有空间恢复且补充储备后才重新准入；储备释放本身不会使普通工作抢走应急余量。真实 SQLite FULL/不可写仍可能发生，此时标记核心故障、停止准入，由 Runtime 收敛；不能依赖再写一个 pending 标记，已有 intent 必须保留，重启扫描为 unknown。

## 有界维护和 WAL

Runtime 仅一个周期 owner，每次 await 一个命令后休眠约一秒，不累计任务；普通队列满则退让，真实核心故障才传播。采样/文件/SQLite 工作在 writer 队列，不在网络 event loop。健康和观测接口读取缓存，最迟随一次维护周期更新；最终准入不依赖缓存。

有安全空间时执行 PASSIVE checkpoint，已全部完成且无读者阻塞时尝试 TRUNCATE；临时 busy timeout 为零，完成后恢复 250ms，长读事务不能使监测无限等待。空间低于停止线时暂停主动 checkpoint，留给已准入关键收尾；外部长期读者仍可能钉住 WAL，水位会停止新工作。被动额度不再新增观察；已发起的有限观察仍受原期限/取消 owner 管理，结果写入也会退让。低水位拒绝新报表，并由已有查询的 SQLite progress handler 尽快取消（原一秒总预算保留）。

只有允许过期的 30 日拒绝诊断可清理，每次最多 100 条，且保留额外空间；不删除账本、未结项、账号审计、Key 审计或完成备份。未实现的 M5 正文缓存不计入可用清理能力。

## 认证运行观测

`GET /api/runtime/storage` 复用管理员 Bearer 或 session/Origin/Host 认证，`Cache-Control: no-store`，没有写操作。未配置管理员接口时不开放此路由。返回固定字段：

- 采样时间、normal/degraded/blocked/unknown、核心可用与存储准入/可选工作标记；不代替账号、授权和恢复基线等完整 readiness。
- 用户可用字节、DB/WAL 字节、实际储备/目标字节、最近 checkpoint log/checkpointed frames 与 busy。空间压力时跳过 checkpoint，帧计数保留最近一次尝试值。
- 当前普通/关键 DB 命令数、最近/最大排队等待微秒、报表 reader 是否活动。
- 进程峰值常驻字节（不是当前 RSS），0—1023 FD 扫描的已用数量与 scanLimit=1024（不是更高编号 FD 的全量统计）。

没有路径、主机/请求/Key/账号 ID、正文或秘密，也不产生高基数 label。当前视图不提供完整 task/连接 tracing；完整混合负载及资源回稳仍须独立容量验收。

## 离线维护

备份、显式迁移和再加密先为源及目标保留可选工作余量（256 MiB），再计快照大小及 8 MiB 操作余量；复制每 128 页复核余量，再加密每页检查。显式恢复到新目标保留至少 128 MiB 加副本大小/8 MiB 余量，并在复制批次复核。不要用离线维护耗尽核心结算空间；读验证旧备份不要求制造新副本。

空间不足输出固定脱敏错误，拒绝发布 manifest/新目标。复制中空间被撤走可以留下私有 partial；恢复保留 restore-pending，普通启动拒绝，原 bundle 不变。保留证据、释放无关文件空间后按[快照维护](snapshot-maintenance.md)改用新目标；再加密保留 checkpoint 和全部 key，按[主密钥维护](master-key-maintenance.md)显式续作。不手动删屏障或回滚账本，不能自动裁掉完成备份来获得空间。

## 合成验证

```sh
swift test --no-parallel --filter 'storage|Storage|pinnedReader|sparseReserve|queuedAdmission|unknownSpace|actualSQLiteFull'
python3 scripts/verify_storage_pressure.py --binary .build/debug/codexone
```

真实空间故障仅在显式提供的隔离 Linux tmpfs 上运行 `--space-root ABSOLUTE_PRIVATE_TMPFS`：脚本要求类型 tmpfs、容量 384—512 MiB，拒绝在普通宿主卷填充。覆盖低水位、实际 ENOSPC、已有流结算、拒绝新派发、回稳、离线空间拒绝，以及 SIGSTOP 暂停实际恢复进程后撤去目标空间、SIGCONT 后逐批拒绝。macOS 验证真实储备文件/SQLite FULL/WAL/认证 API，空间水位以内部测试注入；不填满宿主磁盘，不冒充掉电或目标容量证据。
