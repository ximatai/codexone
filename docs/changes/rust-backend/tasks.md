# 交付与验收

跟踪独立实现与跨后端验证。

- [ ] 有序 JSON 与 SSE 对照 Swift 的边界行为和字节输出。
- [ ] 当前 SQLite 格式、既有凭证与 Key 兼容，合成双向读写。
- [ ] 跨实现验收驱动，独立数据库、端口和合成上游。
  - macOS arm64 合成验证已覆盖 Swift 与 Rust 各自重启及双向正常停机切换。每轮离线只读核对 SQLite v19 和持久结算，并以首轮响应 ID 续接。每次生成只派发一次。
- [ ] 执行事务、准入、账号选择、结算、取消与启动恢复。
  - macOS arm64 合成验证已覆盖两端口的磁盘压力与恢复冻结、普通 writer 队列饱和、写入失败触发关闭，以及启动恢复期间的实例锁交接。
- [ ] HTTP、SSE、WS、压缩、图片、身份刷新与额度任务。
  - macOS arm64 的 Rust debug 网关通过完整 [迁移验收](../../../scripts/verify_migration_readiness.py)。延迟监听的合成 HTTP 提供者获得一次派发，已收到应用请求后的断开与超时保持 unknown，容量用例接受 64 条空闲 WS 和 8 条活跃 HTTP，普通连接达到上限后仍保留控制通道余量。
  - macOS arm64 合成进程验证覆盖托管及单身份原生 WS、HTTP JSON/SSE 桥接、正式共享正文预算、原生图片两种传输配置、固定池账号续接和强停，以及 HTTP/WS 配额预热的跨重启窗口屏障。
  - 额度任务已用 Swift v19 schema 和合成回环提供者验证重置卡丢响应、到期核对和预热 unknown 恢复。托管 HTTP 网关已验证 A18/A19 管理路由、周期观察触发的 HTTP 预热和重启后原操作核对。WebSocket 预热接线、真实订阅和前端联调另验。
  - Rust HTTP 已接入 zstd 流式上传、一次 415 明文协商和可选加密暂存。macOS arm64 的 release 网关通过 `verify_upstream_zstd.py` 完整合成矩阵和 `verify_protocol.py`。[暂存定向验收](../../../scripts/rust_compat/README.md#http-正文暂存故障)覆盖容量耗尽、TCP reset、半途 SIGKILL、目录清理及重启后的明文上传与租约归还。WS 回退接线随 WS 集成验收。
  - macOS arm64 同一 release 二进制的 `--memory-output` 压缩开关对照使用三类 30 MiB 单请求和四压缩加一明文并发场景，各运行三对进程。进程峰值 RSS 差值分别为 2.23–5.41 MiB 和 11.97–20.81 MiB。RSS 同时计入映射页、分配器、解析和网络缓冲。个别对照高于 5/20 MiB 编码工作区预留，原生 Linux RSS、发行许可归档和真实订阅的 chunked 兼容性仍待验收。
- [ ] 管理 API、会话、用量、首页、CLI、备份恢复与现有 SPA 联调。
  - macOS arm64 Rust 网关通过 [U15/O15 与人工释放验收](../../../scripts/rust_compat/README.md#执行保留与人工释放)。覆盖 91 天明细的事务汇总、每轮上限、过期绑定与审计、UTC 汇总在业务日查询中的投影、Key 最近使用、Cookie/CSRF 与 Bearer、CAS 冲突和重启续作。Rust 执行测试另覆盖存储压力暂停、事务回滚、有界增量回收，以及人工释放后迟到证据的修订。
  - 独立 Rust 网关试验以只读 SQLite 事务固定合成 WAL。首轮在压力下保留明细，释放读事务后，同一进程约 60 秒在下一轮继续汇总。
  - Rust 首页资源在 Docker Desktop 的 Linux arm64 原生指令集容器和 Linux amd64 仿真容器均通过 [进程验证](../../../scripts/rust_compat/README.md#用量存储水位与首页推送)，覆盖实际采样、无查看者、HTTP/WS 字段一致和重启清空。最近一小时与 121 条上限使用合成时间样本验证。
- [x] 离线 CLI 与 Swift 双向维护验证，覆盖备份校验、恢复冻结与凭证重加密续作。
  - macOS arm64 与 Linux arm64 的 Rust CLI 通过祖先链接、末级链接拒绝、真实 SIGKILL 恢复屏障及独立空目标重试。macOS 另复跑 Swift/Rust 双向维护、Key 导入与业务日验证。
- [x] 在线备份调度、保留和状态展示。
  - macOS arm64 合成进程验证覆盖分批复制期间结算、Swift/Rust 校验同一 v19 在线快照、SIGKILL 后旧份保留及下一轮清理，以及复制途中 SIGTERM 正常退出。[在线备份验收](../../../scripts/rust_compat/README.md#在线备份与并发结算)复用一次性复制同步点，额外检查重启恢复上次成功、磁盘压力中止、轮转失败及恢复至七份、手工 bundle 保留和 HTTP/WS 状态一致。调度测试加速首次运行，未实等生产 10 分钟与 24 小时间隔。
  - Chrome 连实际 Rust 网关的生产 SPA，合成 50 小时与 73 小时旧备份分别验证 WebSocket 警告和 HTTP 回退严重提醒、占用提醒与存储抽屉。36/72 小时的严格边界用固定时钟单测验证。
- [ ] 独立发布镜像，原生 Linux 混合容量与双向切换演练，报告构建、体积、启动和运行资源。
  - [Rust 候选构建与合成镜像检查](../../../deploy/README.md#rust-候选镜像)可用于集成后复跑，已取得下列 amd64 仿真结果。

## Linux amd64 候选仿真实测

2026-11-21 在 macOS arm64 的 Docker Desktop 4.100.0 上构建并运行 Linux amd64 候选。Docker VM 提供 14 vCPU 和约 16 GiB 内存，使用 BuildKit 0.34.2 与两个 Cargo 构建任务。镜像源码为 `50a2e4696707bd38eb47bda1dce5e2b3e5a05477`，本地 manifest 为 `sha256:8744bd7804641566879e79f84c95866b63343417c51abbd13f322c4f163841ab`，schema v19。镜像内 glibc 为 2.39，维护工具 SQLite 为 3.45.1。

| 项目 | 结果 |
| --- | ---: |
| 空 Cargo 缓存和 `--no-cache` 构建 | 397.87 秒 |
| 同参数热构建（命中全部构建层，manifest 相同） | 7.09 秒 |
| gzip 层存储体积 / 解压后层体积 | 21.42 / 56.11 MiB |
| `docker save` 归档 | 21.44 MiB |
| `docker run` 至 liveness 通过 | 0.252–0.480 秒 |
| cgroup 内存（负载前 / 峰值 / 负载结束一秒后） | 82.53–88.19 / 93.08–95.02 / 88.66–94.45 MiB |
| 每轮 32 个约 64 KiB 的 Responses JSON 请求 | 1.129–1.224 秒，峰值 8 个并发上游请求 |

冷构建使用独立缓存命名空间，计时包含该次仍需下载的基础层和包。镜像基础层已经部分下载。三轮镜像检查各用独立数据目录与回环网络，通过非 root 只读根启动、两个监听器的 liveness/readiness、SPA 资源、SIGTERM、32 条持久结算与离线备份校验。网关限制为 1 CPU、768 MiB、128 PID，内存读数来自 cgroup v2。以已存在的 Swift `0.26.45` 镜像供体积参照，其 gzip 层为 57.83 MiB，解压后 168.11 MiB。两个镜像来自不同源码版本。

原生 Linux 混合容量、完整协议、实际 Compose 安装、上游 TLS 与双向切换仍待验收。

## 相关文档

[架构提案](proposal.md)
