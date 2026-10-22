# 主密钥维护验证 · 2026-10-22

主 Agent 实现/执行，仅临时合成凭证、私有文件和 SQLite，无真实账号调用、额度消耗或部署。

定向证据：

- Swift 多版本 active 写入、legacy/decrypt-only 读取、AAD 隔离、重复/过量/未知字段/复用管理员与静态 Key/硬链接拒绝通过。分页 CAS 的提交后失败留下混合版本与同页检查点；页内 SQLite 触发写失败回滚全部页和检查点，修复外部失败后续作完成。账号 credential version/revision/授权/刷新 intent 保持；正常重启仍按原规则恢复 auth_uncertain。
- v1—v7 显式迁移保留预升级 intent/refreshing；v7 完成 bundle 验证/恢复升级 v8，原只读源不变；旧 key 缺失不发布目标。原始 v7 迁移前备份解密依赖与外部恢复审计要求有定向覆盖。
- `python3 scripts/verify_key_maintenance.py --binary .build/debug/codexone`：真实 keyring 文件、刷新新 active 写入/旧版本共存、在线锁、先完成独立备份；同一维护实现的测试专用进程在持久页提交后实际 SIGKILL，生产服务明确拒绝启动；错误 active/缺 key 续作拒绝；生产 CLI 续作/幂等、维护前后元数据一致、新 key 单独验证/备份/重启通过。不是实际掉电或提供者刷新协议验收。
- 同一场景验证只读旧备份/恢复、完整保留清单与对应恢复目标、保留旧副本时候选移除 key 失败；仅删除本次合成旧副本并更新完整清单后，新 key 单独核对通过。输出/DB/WAL 无材料、合成 token 或私有路径。
- `python3 scripts/verify_snapshot_restore.py --binary .build/debug/codexone` 回归通过，保留恢复基线/CAS/窗口冻结及真实中断屏障。

早期定向测试捕获多版本 open 误用 active key/AAD 而无法解密旧信封，修正为按信封 key ID 选择后通过；没有将失败计为通过。自查发现沿用 v7 会让旧二进制忽略新检查点，因此升 v8，并保留 v7 bundle 显式恢复路径。完整出口与集中 review 结果待完成后补记。

边界：清单完整性、外部 raw 恢复审计及销毁事实由操作者声明，工具无法发现未知副本或自动证明外部审计。原始 v1—v6 备份拒绝退役核对，须保留旧 key，或完成独立副本迁移/恢复后明确处理旧格式副本。Desktop、真实订阅、M5、低磁盘分级保护、实际掉电、目标容量、优化版新 OCI/安装及兼容回退演练继续保留。
