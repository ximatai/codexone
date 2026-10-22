# 存储压力验证 · 2026-10-22

主 Agent 亲自实现并运行，全部临时合成上游/凭证/SQLite；不调用真实账号或部署。

集中 review 前定向证据：

- macOS arm64 / Swift 6.4：实际物理储备和 sparse 替代拒绝、分级/滞回、未知采样关闭准入但保留读取、队列等待后最后复核、低空间关键绑定/结算、长读钉住真实 WAL/零等待 checkpoint、真实 SQLite max_page_count FULL 后 intent 保留/重启 unknown，以及 Runtime 容量退让/取消/核心错误传播通过；受影响用量查询回归通过。物理主机可用空间水位采用 package 内测试注入，未填满宿主卷。
- `python3 scripts/verify_storage_pressure.py --binary .build/debug/codexone` 实际 HTTP：未认证 401、认证 no-store 固定观测、真实储备/峰值 RSS/有限 FD 与周期更新通过。无前端产品代码变更，不重复浏览器全集。
- 首轮 Linux amd64 / Swift 6.4.1 在 2 CPU/2500 MiB、无外部网络的本机容器编译通过，544.57 秒，未 OOM。只填充显式 384 MiB 私有 tmpfs：degraded 停报表、blocked live=200/ready=503/无新上游调用，实际 ENOSPC 下既有流结算成功并释放储备，清理合成 filler 后补储备/回稳；离线备份/恢复/再加密/旧库迁移空间不足拒绝。真实恢复进程在 durable pending 后 SIGSTOP，撤去目标空间后 SIGCONT，逐批复制拒绝，未发布目标，普通启动拒绝，原备份摘要不变。首轮之后新增的收紧权限保留和 256 MiB 维护预算将在最终代码出口重验，不把首轮当作最终快照验收。

空间保护不证明外部进程/硬件失信时仍可结算；SQLITE FULL 不能通过再写 pending 来挽救，已有 intent 才是恢复依据。未测实际掉电、目标宿主容量；峰值 RSS 与 0—1023 FD 观测不是当前 RSS/全量 FD/task tracing。Desktop、真实订阅、M5、新 OCI/安装/兼容回退仍保留。

## 集中 review 与最终出口

- 实现 `a32cab2`；主 Agent 自查修复 `3b7ecf8`：writer 关闭时显式、幂等释放储备 FD；同锁完成用量 reader/activity 交接，避免旧查询覆盖新查询状态。实际 FD 仍引用 store 时归零，6 项相关回归通过。两位 subagent 只读集中 review，修复复审关闭，无剩余明确缺陷。
- macOS arm64 / Swift 6.4、Linux amd64 / Swift 6.4.1：完整后端覆盖各 175 项 Swift 测试，格式/依赖方向/文档，以及全部 14 个进程、维护与协议脚本通过。Linux 为本机 2 CPU/2500 MiB、无外部网络、native 单并发容器，最终退出 0、未 OOM；当前产品代码对应 `3b7ecf8`。
- 首轮完整测试未一次全绿：两平台旧审计夹具在注入核心写失败后仍期望普通管理写；`751cb8c` 明确拒写，并关闭重开后继续原容量/权限收紧断言。macOS 两处全文件隐私扫描对新增 64 MiB 储备使用慢速子序列搜索导致超时；改用 mappedIfSafe/range(of:)，保留包括储备在内的相同完整字节检查，场景降为约 0.43/0.10 秒。两平台只重跑这 3 项受影响测试通过，其余保留首轮通过结果，没有重复全集。
- macOS Images 绑定故障后曾等待固定 unknown 超时，未留最终 state，不能追认当次根因；两次原脚本独立复跑通过。只读复查确认脚本有时序假设：WS sole reader 可先取完整终态证据并合法 settled，或核心先收敛而保留 intent。`6f287bd` / `b77088d` 改为真实重启后要求无该 attempt 绑定、无重放、无 intent；settled 必须完整文本/图片用量与金额精确匹配，否则保留无证据 unknown（HTTP 内存用量也可能在核心故障收敛前来不及持久化）。两平台只重跑该受影响 Images 脚本通过，复审关闭；没有改动生产取证、结算或协议行为。
- 最终 Linux 真实 384 MiB 私有 tmpfs 验证包含最新 256 MiB 维护预算、储备魔数及低空间真实禁用保留：低水位拒报表/新工作，live 保持，真实 ENOSPC 下既有流结算并释放储备，清理后补储备/滞回恢复；离线备份/恢复/再加密/迁移拒绝，以及恢复 durable pending 后 SIGSTOP/撤空间/SIGCONT 的逐页预算失败、未发布目标、原备份不变均通过。

完整命令入口为 `./scripts/verify.sh --backend`；Linux 使用同等检查、native 构建选项，空间脚本增加 `--space-root`。未通过的首轮与定向修复按上述合并覆盖，不表述为一次完整命令全绿。无前端产品变更，不重复浏览器全集；未测试实际掉电、目标弱服务器、发行 OCI 或真实订阅。
