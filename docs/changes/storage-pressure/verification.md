# 存储压力验证 · 2026-10-22

主 Agent 亲自实现并运行，全部临时合成上游/凭证/SQLite；不调用真实账号或部署。

集中 review 前定向证据：

- macOS arm64 / Swift 6.4：实际物理储备和 sparse 替代拒绝、分级/滞回、未知采样关闭准入但保留读取、队列等待后最后复核、低空间关键绑定/结算、长读钉住真实 WAL/零等待 checkpoint、真实 SQLite max_page_count FULL 后 intent 保留/重启 unknown，以及 Runtime 容量退让/取消/核心错误传播通过；受影响用量查询回归通过。物理主机可用空间水位采用 package 内测试注入，未填满宿主卷。
- `python3 scripts/verify_storage_pressure.py --binary .build/debug/codexone` 实际 HTTP：未认证 401、认证 no-store 固定观测、真实储备/峰值 RSS/有限 FD 与周期更新通过。无前端产品代码变更，不重复浏览器全集。
- 首轮 Linux amd64 / Swift 6.4.1 在 2 CPU/2500 MiB、无外部网络的本机容器编译通过，544.57 秒，未 OOM。只填充显式 384 MiB 私有 tmpfs：degraded 停报表、blocked live=200/ready=503/无新上游调用，实际 ENOSPC 下既有流结算成功并释放储备，清理合成 filler 后补储备/回稳；离线备份/恢复/再加密/旧库迁移空间不足拒绝。真实恢复进程在 durable pending 后 SIGSTOP，撤去目标空间后 SIGCONT，逐批复制拒绝，未发布目标，普通启动拒绝，原备份摘要不变。首轮之后新增的收紧权限保留和 256 MiB 维护预算将在最终代码出口重验，不把首轮当作最终快照验收。

空间保护不证明外部进程/硬件失信时仍可结算；SQLITE FULL 不能通过再写 pending 来挽救，已有 intent 才是恢复依据。未测实际掉电、目标宿主容量；峰值 RSS 与 0—1023 FD 观测不是当前 RSS/全量 FD/task tracing。Desktop、真实订阅、M5、新 OCI/安装/兼容回退仍保留。集中 review/修复和最终完整跨平台结果待出口补记。
