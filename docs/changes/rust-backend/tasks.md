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

## 默认镜像与发布门禁

- [x] Dockerfile 和 Release 默认选择 Rust。Compose 继续固定到不可变镜像引用，Swift 过渡镜像通过显式构建参数选择。
- [x] Release 从候选镜像提取 Rust 二进制并与优化导出逐字节比对。四分片、TLS、安装与容量继续组成发布门禁，Swift 专用探针留作独立夹具。
- [x] 核对发布策略、工作流语法、分片清单、文档与安装器静态验证。
- [ ] 在隔离环境构建并安装无后端参数的 Rust 镜像及显式 Swift 镜像，检查 v19 原卷切换。
- [ ] 在原生 Linux amd64 跑整合提交的完整 Release dry-run，核对本次归档、分片与容量证据。

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

该轮仅做镜像合成探测，后续验收结果见下文。

## 同宿主构建对照

同一次对照使用 `7c5a3d9fac8da7e319d9a1f819845188675a88e9`，即集成提交 `d3fc625` 加 Rust 许可归档修正。macOS arm64 Docker Desktop 4.100.0 在隔离引擎内仿真 Linux amd64。构建器相同，配额为 10 CPU、13 GiB，两个后端分别使用 4 个编译任务，依次构建。

| 构建 | Swift | Rust |
| --- | ---: | ---: |
| 冷构建 | 718.98 秒 | 307.12 秒 |
| 热构建 | 2.54 秒 | 2.38 秒 |
| gzip 层 / 展开层 | 55.68 / 168.33 MiB | 22.19 / 60.07 MiB |
| 启动至存活 / 就绪 | 0.584 / 0.715 秒 | 1.610 / 2.124 秒 |
| cgroup 负载前 / 峰值 / 结束一秒后 | 202.30 / 225.57 / 222.54 MiB | 180.63 / 194.68 / 190.77 MiB |
| 请求中位数 / p95 | 0.279 / 0.617 秒 | 0.511 / 1.072 秒 |
| 合成请求成功 / 失败 | 32 / 0 | 32 / 0 |
| 冷、热共用镜像 ID | `sha256:c14a60e7114d79376b93cf1ab42301c0fce0cae7266a935d77362f6784c7569b` | `sha256:00475265809b1a94059feaee993d5f72b8602943b8eec876b0881769c823812c` |

两个冷构建均预拉并核对固定 amd64 基础层，复用同一前端构建缓存，分别禁用后端和运行根装配层缓存，使用空编译产物缓存。Swift 30 个锁定 revision 由预处理的本地镜像提供。Rust 预取过 Cargo 依赖，计时日志仍记录部分 crate 下载。两个冷计时都含系统包获取和镜像输出。热构建由同一命令去掉禁用缓存的参数复跑。运行数字来自每个后端一次 8 并发、32 个约 64 KiB Responses JSON 请求的探测，合成上游固定等待 250 ms。隔离 Docker 的保存层为未压缩，gzip 体积统一使用级别 6 计算。

## 更新基线的隔离镜像验收

第一轮更新候选以集成提交 `0b9aa6f` 为基线，镜像标记为 `6386a62fb53b25ff1f5d58b0ef4b84854fa5dfd2`。复用较早的 Cargo 目标缓存时，首次更新构建复现 `E0599`。源码包含所需的 `supported_reasoning_efforts`，但源码归档时间戳早于目标缓存，Cargo 复用了旧 crate。修正后继续使用同一缓存命名空间，日志确认重新编译 `codexone-config` 与其他工作区 crate，优化镜像构建成功。

上方冷、热构建数据保留原始配对提交。隔离运行复测导入同一镜像 ID 到独立无网引擎，避免构建引擎的 threaded cgroup 拦截运行时的 domain 控制器。运行预检核对每个负载网关的 1 CPU、768 MiB、零交换空间及 128 PID。

许可审计核对 `Cargo.lock` 中 183 个 registry 包的归档校验和。对实际 Rust 候选中的 344 个许可文件进行逐文件哈希比对，全部匹配，其中 12 个 `COPYRIGHT` 或 `UNLICENSE` 文件由本次补收。内嵌 zstd 1.5.7 C 实现的 BSD 正文和 GPLv2 `COPYING` 均随镜像归档，连同 Rust 包装层的 BSD 许可材料。Linux amd64 的正常和构建依赖图排除了缺少单独许可正文的 UEFI 与 Wasm 专用 crate。

此版混合负载两边都完成 30 次预期上游派发与账本核对，管理探针零失败。Swift 通过三轮回稳。Rust 三轮末尾的 RSS 中位数为 100.05、164.07、164.07 MiB，回稳增量约 64 MiB，超过 32 MiB 验收门槛。cgroup 内存峰值为 Swift 377.19 MiB、Rust 479.49 MiB。

真实 Nginx TLS 套件在 Swift 上通过。Rust 通过证书与主机名校验、HTTPS 会话、转发头隔离和管理 WSS，随后在请求尺寸场景未返回预期的 HTTP 413。两套 Compose 运行到末尾的容器日志检查，测试器在 root 的隔离控制环境中调用了缺失的 `sudo`。测试器已兼容 root 直接读取日志目录。

## 最终集成基线复跑

以 `c3f4d7a` 加发行构建与验证修正生成候选，两个镜像都标记为 `2861834209eecdb3f51e0c3d70f73b3415f39035`，schema v19。沿用同一构建器和已有工具链缓存，Swift/Rust 本次增量构建分别为 14.48/67.99 秒。宿主为 macOS arm64，Docker Engine 报告 aarch64，候选容器报告 x86_64。两边均导入同一无网运行引擎，以 1 CPU、768 MiB、零交换空间、128 PID 运行同一合成探测。

| 简单 HTTP 探测 | Swift | Rust |
| --- | ---: | ---: |
| gzip 层 / 展开层 | 55.68 / 168.33 MiB | 23.10 / 62.51 MiB |
| 启动至存活 / 就绪 | 0.452 / 0.609 秒 | 0.249 / 0.364 秒 |
| cgroup 负载前 / 峰值 / 结束一秒后 | 164.44 / 187.16 / 186.66 MiB | 89.41 / 97.18 / 90.69 MiB |
| 完成请求中位数 / p95 | 0.265 / 0.556 秒 | 0.269 / 0.307 秒 |
| 合成请求成功 / 失败 | 32 / 0 | 32 / 0 |

三轮混合负载使用同一批合成上传、输出、大图、慢消费者和断连场景，两边均启用 HTTP 加密暂存并关闭上游压缩。刺激容器也限制为 1 CPU、512 MiB。回稳取每轮 60 秒尾段最后十个样本的中位数。请求百分位计入合成慢消费者与上游阻塞等待。

| 混合负载 | Swift | Rust |
| --- | ---: | ---: |
| cgroup 空闲 / 峰值 | 98.95 / 376.70 MiB | 86.24 / 416.53 MiB |
| cgroup 三轮回稳中位数 | 181.59 / 184.22 / 184.55 MiB | 160.34 / 224.57 / 224.77 MiB |
| 进程 RSS 三轮回稳中位数 | 150.04 / 152.36 / 152.50 MiB | 99.99 / 164.00 / 164.07 MiB |
| 完成请求中位数 / p95 | 0.757 / 5.482 秒 | 0.759 / 5.188 秒 |
| 完成 / 预期取消 / 意外失败 | 24 / 6 / 0 | 24 / 6 / 0 |

两边各派发 30 次，账本核对通过，管理探针零失败，无 OOM。Swift 通过整套混合验收。Rust 复现回稳门槛失败，第三轮 RSS 较首轮上升约 64.08 MiB，超过 32 MiB。原生 amd64 的容量验收仍未取得。

实际 Compose 安装在两套镜像上均通过，包括 SPA 与会话、非 root 只读运行、Key 持久化、v5 备份迁移、SIGKILL 恢复和有界日志。合成双向切换、Rust HTTP 暂存容量/断连/SIGKILL 恢复和 zstd 上传矩阵通过。

真实 Nginx TLS 套件在 Swift 上通过。Rust 通过信任链与主机名、HTTPS 会话和管理 WSS，完整套件停在一条未送正文且缺少 `Content-Type` 的 `64 MiB + 1` 字节声明。不带媒体类型时 Swift 返回 413 `request_too_large`，Rust 返回 415 `unsupported_content_type`。同一声明加上 `Content-Type: application/json` 后两边都返回 413，两组探测均无派发与账本记录。P13 规定 JSON 输入、网关 64 MiB 与 Nginx 65 MiB 边界，P26 的共享正文预算段规定单条超过 64 MiB 返回 413。既有 `limits_checks` 固定了缺少媒体类型时的可观察行为。分项复跑确认两个数据别名的 Nginx 65 MiB 限制返回 413，HTTPS JSON、逐步 SSE、代理超时、数据 WSS、HTTP-to-WS 桥与两种 WSS 取消均通过。独立合成检查中，两套网关的 HTTP/WSS CONNECT 均拒绝不可信上游证书，目标未收到应用数据。较广的代理脚本在 Swift 止于取消场景的三秒 CONNECT 观察门槛，在 Rust 则通过代理及 TLS 检查后进入需要 Swift 测试专用 `ExecutionProbe` 的管理授权阶段。[协议规范](../../reference/specs/protocol.md) · [TLS 既有用例](../../../scripts/verify_tls_proxy.py)

## 回稳采样复跑

在同一对 `2861834` 镜像上用 `verify_mixed_capacity.py --emulated --recovery-detail` 重放三轮。每轮停止数据面刺激后等长观察 60 秒，保留原有管理探针和 32 MiB 回稳门槛。报告以进入回稳后的第一个观测值描述轮末，用每轮尾段最后十个样本的中位数描述回稳。进程页类型来自 `/proc/1/status` 的 `RssAnon` 和 `RssFile`，cgroup 文件页来自 `memory.stat` 的 `file`。TCP 计数按网关进程拥有的 socket inode 归属，结算状态由只读 SQLite 查询统计。

| 后端 / 轮次 | 总 RSS | 匿名 RSS | 文件 RSS | cgroup 文件页 |
| --- | ---: | ---: | ---: | ---: |
| Swift 1 | 150.05 → 150.06 | 106.36 → 106.37 | 43.69 → 43.69 | 64.78 → 64.81 |
| Swift 2 | 152.31 → 152.31 | 108.62 → 108.62 | 43.69 → 43.69 | 65.25 → 65.15 |
| Swift 3 | 152.50 → 152.50 | 108.81 → 108.81 | 43.69 → 43.69 | 65.63 → 65.53 |
| Rust 1 | 99.99 → 100.00 | 86.08 → 86.09 | 13.91 → 13.91 | 65.43 → 64.44 |
| Rust 2 | 163.93 → 163.93 | 150.02 → 150.02 | 13.91 → 13.91 | 65.48 → 64.52 |
| Rust 3 | 164.61 → 164.61 | 150.70 → 150.70 | 13.91 → 13.91 | 65.56 → 64.61 |

数值单位为 MiB，箭头为轮末首个观测值到尾段中位数。每轮 26 个样本，覆盖首末观测之间约 57.8 秒。两边所有回稳观测中网关持有的活动 TCP 和账本 `intent` 均为 0，`unknown` 随每轮确认派发后的预期取消由 1 增至 3。Rust 第三轮尾段总 RSS 较首轮增长 64.61 MiB，同一候选的前一次为 64.08 MiB。此次增长与匿名 RSS 增量一致，文件 RSS 全程为 13.91 MiB，cgroup 文件页尾段中位数只增加约 0.17 MiB。采样定位到匿名驻留，分配来源和生命周期仍待核对。Swift 通过，Rust 仍触发既有 32 MiB 门槛。

剩余门槛包括 Rust 混合负载回稳和 TLS 请求拒绝契约。O14 仍要求在原生 Linux amd64 的 1.6 GiB 参考宿主或可解释的等效约束下验收完整负载包络。O11 要求用将发布的同一优化镜像完成全部验证分片、TLS 与安装再转交发布。真实 Desktop/订阅组合仍按 P11 的验收矩阵验证。[运维规范](../../reference/specs/operations.md) · [发版规则](../../development/releasing.md) · [协议规范](../../reference/specs/protocol.md)

## TLS 拒绝顺序与匿名内存定位

修正候选 `45cff31` 的 Rust Linux amd64 镜像 ID 为 `sha256:0f651ce765191de59c8ed7ead187192835e6dc09d02374b55f2a7113dae0f6c1`。沿用同一台 macOS arm64 宿主的 AArch64 Linux VM，确认容器二进制由 Rosetta 执行。两个数据前缀的 HTTP Responses 在认证后、媒体头检查前拒绝超过 64 MiB 的声明长度，沿用已有 413 错误及入口限额诊断。候选镜像的二进制和 SPA 通过完整 `verify_tls_proxy.py --binary … --web …`。追加的八个 TLS 探针涵盖两个 Responses 前缀，分别以无媒体类型、`text/plain` 和 `application/json` 声明 64 MiB + 1，均返回 413。恰好 64 MiB 且无媒体类型返回 415。八次拒绝均未发送正文，合计零派发、零新增 attempt。

候选按原条件运行 `verify_mixed_capacity.py --emulated --recovery-detail`，三轮各保留 60 秒回稳窗。完成 24 次、按计划取消 6 次、意外失败 0 次，派发 30 次，账本检查通过，管理探针零失败，无 OOM。容器 cgroup 空闲 85.95 MiB、峰值 415.34 MiB。每轮尾段中位数如下，单位为 MiB。

| 观测值 | 第 1 轮 | 第 2 轮 | 第 3 轮 |
| --- | ---: | ---: | ---: |
| 总 RSS | 99.81 | 163.77 | 163.84 |
| 匿名 RSS | 86.05 | 150.01 | 150.09 |
| 文件 RSS | 13.76 | 13.76 | 13.76 |
| cgroup 文件页 | 64.44 | 64.54 | 64.66 |
| cgroup 总内存 | 160.42 | 224.62 | 224.78 |

第三轮总 RSS 较首轮增加 64.03 MiB，仍超过既有 32 MiB 门槛。所有回稳样本中，网关活动 TCP 和账本 `intent` 均为 0，`unknown` 随已派发的预期取消由 1 增至 3。

固定 `2861834` Rust 镜像做分段诊断，沿用 1 CPU、768 MiB、零 swap 的网关与 1 CPU、512 MiB 的刺激容器。将混合脚本中的两路 40 MiB、单字符串 64 MiB、结构化 64 MiB、派发后取消 64 MiB 及 32 MiB 恢复请求分段，去掉原生图片并在每段后采样 12 秒。前两次结构化请求使匿名 RSS 从 15.21 MiB 升至 85.99 MiB，再升至 150.02 MiB，第三次维持 150.02 MiB。第一轮结构化请求后最大的可写匿名映射为 72.91 MiB，第二次后为 136.93 MiB，第三次保持 136.93 MiB。两次结构化请求间的其他分段保持约 86 MiB。文件 RSS 固定为 13.68 MiB。结构化阶段的回稳采样中，网关持有的已建立 TCP 连接及账本 `intent` 均为零。

另在同一参考二进制中临时加载只输出汇总计数的 glibc 探针。复现 149.95 MiB 匿名驻留时，`mallinfo2` 报告 arena 内使用中 1.65 MiB、空闲 135.29 MiB、独立映射 1.30 MiB。空闲时手动调用一次 `malloc_trim(0)` 后，匿名 RSS 降至 14.99 MiB，arena 仍有 135.18 MiB 空闲虚拟容量，使用中保持 1.65 MiB。随后负载再次触及这些页，第三轮结构化请求结束后匿名 RSS 回到 150.05 MiB。另一次在 86.10 MiB 平台调用时匿名 RSS 降至 15.14 MiB。这些读数将本次阶跃定位到仿真环境中 glibc arena 的空闲驻留页。探针、信号和手动回收仅用于诊断，当前候选沿用发行时的分配器配置与资源配额。原生 amd64 同条件复测可确认该现象是否也会触发 O14，并为是否改变回收策略提供依据。

## 原生 Linux amd64 对照

从整合提交 `f34fdd1` 冷构建 Rust 镜像，在 GitHub Actions 的 Ubuntu 24.04 x86_64 runner 和原生 amd64 Docker 引擎上验证。runner 提供 4 个 Xeon 6975P-C vCPU 和约 15.3 GiB 内存，使用 cgroup v2。网关限制为 1 CPU、768 MiB、零 swap，刺激端为 1 CPU、512 MiB，均使用隔离网络和合成数据。容量使用原版 `verify_mixed_capacity.py --recovery-detail`，保留三轮各 60 秒回稳和 32 MiB 门槛。

基线镜像 `sha256:91525859509e1a5e96d0335e971b1a7e23293c85101b622afc5336a634f3788d` 通过包装检查和完整 Nginx TLS。混合流程完成 24 次、预期取消 6 次、意外失败 0 次，派发 30 次，账本核对通过。三轮尾段 RSS 为 88.61、88.61、152.62 MiB，第三轮增加 64.01 MiB，容量门槛失败。匿名 RSS 为 75.19、75.18、139.20 MiB，文件 RSS 固定约 13.42 MiB，cgroup 文件页尾段约 64.33、64.35、64.38 MiB。所有回稳样本的活动 TCP 与账本 `intent` 均为 0。[原生基线运行与归档](https://github.com/ximatai/codexone/actions/runs/44865890700)

修正候选 `740b982` 先释放解析文档和编码缓冲，再使用现有暂存 worker 对至少 32 MiB 的加密重写执行一次 glibc 页回收。发行参数、正文预算和验收门槛沿用。镜像 `sha256:3bc593ccfa10c0e34afa40fc8a3d2b3e570fa985e5852a8d49b94b8340b61264` 在同类型独立 runner 上通过容量门槛、包装检查、完整 Nginx TLS、HTTP 暂存断连及 SIGKILL 重启复测、合成 zstd 矩阵。镜像归档在 runner 重载后按相同 ID 验收。

| 原生混合负载 | 基线 | 修正候选 |
| --- | ---: | ---: |
| 三轮回稳 RSS（MiB） | 88.61 / 88.61 / 152.62 | 18.20 / 18.35 / 18.33 |
| 最大 RSS 回稳增量（MiB） | 64.01 | 0.15 |
| cgroup 空闲 / 峰值（MiB） | 71.73 / 340.96 | 71.81 / 338.04 |
| 完成请求 p50 / p95（秒） | 0.654 / 4.314 | 0.711 / 4.343 |
| 管理探针 p95 / 最大值（毫秒） | 0.84 / 171.01 | 0.92 / 217.43 |
| 完成 / 预期取消 / 意外失败 | 24 / 6 / 0 | 24 / 6 / 0 |

两次运行均保持两路 40 MiB 上传并发、两个并行原生图片输出、30 次派发和 627 次成功管理探针，无 OOM。修正候选三轮的匿名 RSS 尾段为 4.30、4.45、4.43 MiB，活动 TCP 与账本 `intent` 均为 0，既有取消留下的 `unknown` 计数为 1、2、3。延迟来自同机型两次独立运行。剩余验证包括 O11 最终发布镜像的所有分片和安装，以及 O14 约 1.6 GiB 整机约束下的完整负载包络。[修正候选运行与归档](https://github.com/ximatai/codexone/actions/runs/44866706438)

## 定版发行镜像与两项协议复查

固定 `11e92c0` 的 Rust 原生 amd64 镜像通过容量、完整 Nginx TLS、加密暂存故障恢复、实际 Compose 安装及备份恢复/日常维护。原生容量三轮 RSS 为 17.68、17.74、17.79 MiB，最大增量 0.11 MiB。标准 Verify 全部通过。用同一归档加载优化 Rust 网关运行扩展分片，补齐共享文本夹具后 45 项中 30 通过、6 失败、9 未运行；后者依赖 Swift 专用探针或属于独立于产品二进制的工具与源码检查。[定版镜像验收](https://github.com/ximatai/codexone/actions/runs/44867789791) · [标准 Verify](https://github.com/ximatai/codexone/actions/runs/44867656559) · [同归档夹具复跑](https://github.com/ximatai/codexone/actions/runs/44868277082)

在 `11e92c0` 基线上修复两项既有行为。HTTP 桥接按实际 WS 编码长度先拒绝超限续接，等于阈值时仍按订阅 HTTP 参数校验处理。原生定向验证确认超阈值一字节为 413，等于阈值为 400，两个拒绝均无新增派发和 attempt，原有原生 WS 续接仍可用。共享 WS 阈值冒烟套件在 Responses 与 Codex subscription 两种契约上通过。首页记录当前进程实际提交的速率样本，用于区分启动秒或历史时钟范围内的结算归属。原生定向验证收到已结算请求的 Key 聚合及匹配账本的近 60 秒和分日速率，Rust 用量及执行测试通过。共享管理 WSS 已通过通常的升级、结算推送及关闭检查，独立的 SQLite 故障用例重命名核心 attempts 表后连接关闭，尚未验证读源恢复快照。其余扩展分片差异继续独立跟进。[原生定向复查](https://github.com/ximatai/codexone/actions/runs/44868885506)

## 管理读源降级与核心写入故障隔离

固定 `a970e0f` 重新构建原生 amd64 Rust 归档，并让所有分片校验和加载同一归档。容量三轮回稳 RSS 为 17.44、17.50、17.54 MiB，最大增量 0.10 MiB；TLS、加密暂存、Compose 安装、SQLite 备份恢复及维护通过。保留共享只读夹具后，扩展分片 35 通过、1 失败、9 项因 Swift 专用探针或独立工具跳过。失败项为旧版管理 WSS 故障夹具。标准 Verify 的后端检查通过，Chromium 实时和 HTTP fallback 用例在布局偏移为零的断言失败。[原生集成镜像](https://github.com/ximatai/codexone/actions/runs/44869387725) · [标准 Verify](https://github.com/ximatai/codexone/actions/runs/44869344670)

诊断镜像保留旧夹具的临时全表重命名。管理 usage reader 先报告缺表，WSS 首帧如实报告 unavailable。故障持续至下一次保留维护时，执行 writer 在 `ledger::maintain` 首次遇到致命缺表，进程约 60 秒后退出 1。Rust 管理脚本现单独注入已结算速率的读取类型错误，保留表与正常写入路径。未改动的 `a970e0f` 镜像在此故障中报告初始 unavailable/data:null，能继续派发并结算新的合成请求，恢复值后同一 WSS 报告 fresh。独立的核心绑定故障仍导致非零退出并释放两个 listener。[角色追踪与同归档验证](https://github.com/ximatai/codexone/actions/runs/44869728040)

后续管理控制帧检查定位到 Rust 缺失既有的每连接每秒 64 帧限制。修正候选 `5f6d572` 对第 65 帧发出 1008。原生优化二进制通过完整管理 WSS，观测到超限关闭帧、健康 viewer 的后续更新、HTTP 会话和替补 viewer 正常。核心绑定故障退出、完整 WS 超限矩阵和真实 Nginx TLS 均通过。待最终整合 SHA 再构建与验收发行归档。[修正候选定向验证](https://github.com/ximatai/codexone/actions/runs/44870085027)

## 执行账本重启 QA

在 macOS arm64 从 `8f68c4b` 构建 Swift 和 Rust debug 网关。正常重启对照通过两端各自重启及双向切换，四组都保持 schema v19 和首轮结算，续接前上游调用为 1 次，续接后为 2 次。

[执行账本重启驱动](../../../scripts/rust_compat/README.md#执行账本重启恢复) 在正式 Rust 网关进程通过四个 SIGKILL 场景、恢复后继续执行，以及再次正常重启后的账本一致性。旧工作树留下的合成对照构建省略启动时的 intent 恢复，驱动在第一个有 intent 的场景以 `expected unknown, found intent` 失败。同一 Rust 构建也通过 `readiness.py` 和 `verify_protocol.py`。原生 Linux amd64 发行制品仍待运行同一重启入口。

### Swift ExecutionProbe 覆盖盘点

| 覆盖 | Rust 证据与剩余范围 |
| --- | --- |
| 执行持久化（`verify_execution.py`） | 正式监听器已覆盖四个重启场景及恢复后的单次派发。直接重复提交同一结算证据和探针的容量命令仍由各自的定向用例覆盖，HTTP 驱动不注入内部命令。 |
| 账号刷新恢复（`verify_accounts.py`） | 仍需正式 Rust 进程联验刷新 intent 前、intent 后、提交后的三段退出恢复，核对凭证版本、未知状态拒绝再次刷新及密文扫描。 |
| 托管账号管理与代理（`verify_admin_round2.py`、`verify_upstream_proxy.py` 的 OAuth 分支） | 已有 Rust 托管账号与 SPA 局部证据，仍需整组复跑会话、授权、刷新和观察，并确认 OAuth 与 quota 请求经过显式代理，核对日志和账本脱敏。 |
| 管理实时慢接收方（`verify_admin_live.py --slow-only`） | 正式监听器已有通常升级、快照和关闭证据。仍需让 Rust 进程承载满 DTO 和事件风暴，复验慢连接退槽、七个健康连接存活及 RSS 上限。 |
| 凭证重加密（`verify_key_maintenance.py`） | 已有 Swift 中断、Rust 续作的维护互操作证据。仍需用 Rust 自行中断，验证页与 checkpoint、启动拒绝、正确 keyring 续作及退役核对。 |
| 磁盘压力下的恢复复制（`verify_storage_pressure.py --space-root`） | Swift 探针只负责种库。仍需在原生 Linux 的有界私有 tmpfs 中，由 Rust CLI 验证恢复复制途中撤去空间、pending 屏障与源 bundle 完整性。 |

## 相关文档

[架构提案](proposal.md)
