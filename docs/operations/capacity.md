# 有界合成容量演练

使用有界合成负载测量网关资源、拒绝和故障回收。

## 前提

按 O14 显式执行，独立于例行后端验证。使用本机已验候选和带 Python 的 verification 镜像，不调用真实账号/付费模型，不连接旧服务。Docker Engine 需支持 Linux amd64、cgroup v2 的 memory/cpu 计数、本地命名卷和共享网络 namespace；在 arm64 Engine 上运行 amd64 会包含仿真开销，不能推导原生目标 CPU 吞吐。

```sh
# 新的工作负载/夹具先短程检查；已通过且未改变时不重复。
python3 scripts/verify_capacity.py --image codexone:candidate \
  --harness-image codexone:verification --duration 10 \
  --output artifacts/capacity-smoke-001
# 两种上游分别持续600秒；输出目录必须是新的。
python3 scripts/verify_capacity.py --image codexone:candidate \
  --harness-image codexone:verification --duration 600 \
  --output artifacts/capacity-run-001
```

`--transport http|websocket|both` 决定上游配置；HTTP 配置只测 JSON/SSE、classic compact 和图片，原生 WS 配置另测下游 WS/warmup，同时包含 HTTP→WS 桥接。不要要求 HTTP 上游配置开放下游 WS。`--duration` 为每种配置10—900秒；短程不等于持续容量验收。镜像解析为不可变 ID，报告保留运行源 revision。

## 资源与负载边界

网关是实际运行镜像，非 root/只读/禁止提权/无 capabilities，1 CPU、768 MiB、128 PID、不允许容器 swap，数据放在本次独占 Linux 本地卷。压测器/提供者单独 cgroup（1 CPU/512 MiB/128 PID），只与网关共享隔离 loopback namespace；没有 Docker socket 或外网，不占网关的进程配额。SDK 镜像仅用于合成提供者/压测，不把 SDK 内存当运行镜像内存。

每阶段有一个监督者：基线、覆盖、24路超载、有限断流、持续、回稳。持续流量名义4请求/秒、最多4个在途；满时记录 skipped，而非无限堆积。每次调用有有界正文和网络/执行期限。多 Key 使用不同主体。图片为程序生成的有效1024×1024 RGB PNG，约3 MiB，每次生成/编辑的内容验证在私有内存完成；无用户图片/正文进入报告。未知项保留，不能清账或赠送额度以维持压测。

合成用量明确报告 cached_tokens=0；漏报按产品契约成为 partial/unknown，用量未知明确提醒，不能归因于容量不足或通过放宽限额绕过。压缩 opaque 输出每次唯一，不能跨独立任务复用。提供者对含唯一合成 invocation 的请求做有界指纹检测，重复调用直接使样本失败；不记录这些正文或秘密。

压测结束核对：无 intent，断流使用独立 Key/主体，按主体核对其恰有两个 unknown/两单位预留且无完整用量证据，其他已派发正常项全为 settled；提供者调用数等于持久 attempt 数；正常响应完成、超载有界拒绝。普通数据连接由dataConnections配置（默认128，8—1024），另有固定16条控制余量；连接级关闭、普通容量503与Key/全局准入429须按实际结果分别统计。目标宿主须按当前连接配置重新运行演练，不能将连接失败算成 HTTP 429。回稳时要求至少两个5秒内的新鲜存储DTO，基线/持续/回稳均有样本，核心正常、队列归零，检查当前 RSS 仍在预算内、FD 回到基线附近，cgroup 无 OOM、swap 上限0，最后正常停止。所有未知责任先入报告，再回收本次独立合成卷；这不是对运行中数据的清账。标签只允许删除本次资源，卷创建前即建立清理 owner，root 初始化容器也有本次标签和资源限制；即使命令超时未返回容器 ID 也会按本次随机归属清理。

## 指标解释和不能推出的结论

- `operations` 为每类调用数量/状态、整次操作p50/p95/max与响应字节；`completedSustainedRPS` 使用实际持续和收尾时间。包括合成提供者处理、客户端和仿真成本；不是模型吞吐上限或真实订阅速度。
- 网关 PID1 当前 RSS 来自 `/proc`；cgroup current/peak 包含文件页缓存和短命采样 helper。存储 API 的 peakResidentBytes 是进程历史峰值，不能当当前 RSS。FD/线程每约2秒采样，因此是采样峰值；线程数不是 Swift async task 数。CPU usage/throttle 为实际 cgroup 累计计数。
- storage 保存认证固定 DTO：DB/WAL/储备、checkpoint、writer排队/等待与用量reader。WAL/queue 指标按周期采样，最大等待为累积高水位；不要把没有采到峰值当作没有峰值。
- `vmBefore/vmAfter` 给 Linux VM 内存/可用/swap/负载；报告还列 Engine CPU/架构与共存容器数量。1 CPU/768 MiB cgroup 不能代证约1.6 GiB宿主的OS/共存服务预算；使用共享或仿真环境时必须明确记录参考宿主差异。

此包络覆盖单参考图、HTTP Images generation/edit、JSON/SSE与WS文本/warmup/compact；不代表当前 24 MiB 图片合计上限、16 张参考图或所有最大帧组合均已覆盖、完整图片流/工具峰值、HTTP keepalive与长寿命多turn连接压力、真实提供者迟延分布、Swift async task tracing或实际旧服务混合负载。正文恢复缓存未实现，不伪造缓存压力/恢复重播。低磁盘/WAL/备份不足的独立真实故障证据见[存储压力](storage-pressure.md)。结果只能用于当前合成包络和后续调参，不据此扩大已公布硬边界或宣布O14/首版完成；公开状态与路线图见[STATUS](../../STATUS.md)。

故障保护可独立运行：

```sh
python3 scripts/verify_capacity_guards.py --image codexone:candidate \
  --report artifacts/capacity-600/report.json
```

此检查用真实Engine创建卷/初始化容器，再注入CLI结果丢失，确认本次资源回收；并用报告验证恢复样本拒绝陈旧、缺失或未归零队列。不会重跑持续负载。报告应区分聚合统计与逐请求责任证据，记录实际测量与工具版本。

## 相关文档

[文档导航](../README.md)
