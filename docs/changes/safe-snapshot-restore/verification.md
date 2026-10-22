# 安全快照维护验证 · 2026-10-22

主 Agent 实现与执行，仅临时合成身份/账号密文/上游/SQLite，无真实账户、额度或部署。

定向证据（集中 review 前）：

- macOS arm64 / Swift 6.4：受影响 Adapters 84 项通过；后续 Core 核对状态转换、CAS、只读源修复后，快照/中断/审计基线和历史显式迁移 10 项定向测试通过。覆盖 v7 维护状态、intent→unknown、缺失行、旧 Key/绑定失效、账号 requires_auth、错误密钥/篡改/目标覆盖拒绝、旧窗口冻结、跨窗口缺失占用、审计修订 CAS/幂等及再次恢复继承占用。
- `python3 scripts/verify_snapshot_restore.py --binary .build/debug/codexone` 通过实际 CLI/进程：在线锁拒绝；离线完整 bundle/摘要/0700/0600；原服务备份后再执行，恢复库确实缺该行；重启维护态/503 maintenance_required/不调用上游、旧 Key 401、显式基线/冻结后仍 503，临时合成时间移至新日后新 Key 200；不存在产品时钟绕过开关。
- 只读 bundle 可恢复；缺 manifest、坏摘要、链接、宽权限均不发布目标。实际 32 MiB 合成零页扩大快照，在持久 restore-pending 后 SIGKILL 恢复进程，普通 status/启动拒绝不完整目标，未产生可准入空库，源快照摘要不变。
- 实际单主密钥解密依赖由 SQLite/Swift 集成测试验证，错误/缺失密钥在新目标发布前拒绝；多版本轮换不在本闭环内。

初次失败：macOS 临时目录包含系统路径别名，SQLite NOFOLLOW 打开复制目标失败；改用 POSIX realpath 解析已独占创建的私有文件，保留最终 NOFOLLOW 校验后通过。SQLite Backup API 可能改变复制目标的页头，不能拿第二次复制结果与原文件逐字节比较；改为核对原备份复制前后摘要不变，并通过目标 SQLite schema/quick_check 验证副本。两个失败均没有成功 manifest/可接单恢复目标，不计通过。

集中 review 在实现提交 `7bd70ba` 后进行；发现新目标父目录未同步（P1）、跨 UTC 午夜冻结下限与 legacy 配置虚假就绪（两项 P2）。主 Agent 以 `704ebd5` 修复，12 项定向 Swift 和真实 CLI/HTTP/SIGKILL 回归通过，两位 reviewer 只读复审关闭；未委派实现。父目录同步故障注入证明失败不发布，不作为掉电证据。

阶段出口：macOS arm64 / Swift 6.4，`./scripts/verify.sh --backend` exit 0：159 项 Swift 测试、格式/文档/依赖检查，以及快照、进程/执行/账号、HTTP/SSE/WS/context/压缩、Images、Key、session 与池配置的全部后端脚本通过。Linux amd64 / Swift 6.4.1 对应 `704ebd5` 的完整公开源码快照，2 CPU/2500 MiB、无网络、native 单并发：`swift test --build-system native --no-parallel -j 1 -Xswiftc -driver-batch-size-limit -Xswiftc 16` 的 159 项测试及同一组全部 Python 后端脚本、文档/架构/格式检查通过，exit 0、未 OOM，容器已回收。构建 190.51 秒；不是远端 CI、目标弱服务器容量或优化版 OCI 验收。原 v6 候选镜像保持原版本，未用其冒充本轮代码。没有前端产品变更，不用重复原有浏览器/前端全集代替本闭环；操作界面是离线 CLI。Desktop、真实订阅、M5、公共部署、掉电、主密钥轮换、完整低磁盘保护和目标容量继续保留。
