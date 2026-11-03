# 上游 HTTP 请求体 zstd 压缩提案

仅方案，待评审后实现。目标是减少大请求上传量，同时控制当前已知的内存压力。规范基线：[协议 P05/P06/P08/P10、P27 及 WS 大请求边界](../../reference/specs/protocol.md)、[用量 U13](../../reference/specs/usage.md)、[执行生命周期](../../reference/specs/execution-lifecycle.md)、[运行容量](../../reference/specs/operations.md)。实现时同步规范；本次不改行为、依赖或 schema。

## 依赖与发行证据

固定 `https://github.com/meta/zstd.git` 的 **v1.5.7**（SwiftPM `.exact("1.5.7")`，tag 对应 commit `f8745da6ff1ad1e7bab384bd1f9d742439278e99`），使用 `libzstd` product/target；只在 Adapters/Upstream 加薄封装，负责 C context、分块、错误和释放，不把 C/NIO 类型带进 Core，不引入 gzip 或插件抽象。

- [上游 Package.swift:1–35](https://github.com/meta/zstd/blob/v1.5.7/Package.swift#L1-L35)：tools 5.0、macOS 10.10 起，gnu11，直接编译 common/compress/decompress/dictBuilder，无传递包依赖。2026-11-03 在独立临时包用该 tag checkout 的本地依赖，macOS 27.2 arm64、Apple Swift 6.4.2，实测 `import libzstd`、流式编码和 release 链接通过。未修改本项目 manifest/锁文件。
- Linux **推断可构建，未实测**：[上游 dev-short-tests.yml:74–106](https://github.com/meta/zstd/blob/v1.5.7/.github/workflows/dev-short-tests.yml#L74-L106) 配置 Ubuntu C 构建/测试及 Ubuntu/macOS CMake 矩阵；该 tag 未发现 SwiftPM CI。结合无 Apple 框架的 C target、本项目 `.github/workflows/verify.yml:52` 的 Ubuntu 24.04 / Swift 6.4.1，仅证明可行性依据，不能宣称 Linux SwiftPM 或网关集成已通过。实施后须在原生 Linux CI 验收，不在 Mac 上构建 Linux。
- 构建成本：临时消费者 `swift build --build-system native -c release -j 1` 冷构建 10.71 秒（含薄测试程序、32 个 C/汇编编译步骤），无改动重建 2.40 秒；网络获取不计入。release 探针 423,784 字节，Foundation 空程序 52,056 字节，差约 363 KiB，含探针自身代码，**不是网关/镜像增量测量**。预计静态链接增加数百 KiB 量级代码，无需额外运行时 libzstd 包；完整源码 checkout/对象只增加构建缓存，最终镜像另增加许可证。Linux 二进制、镜像压缩层、冷构建时间均待测，不能套用 Mac 数值；`deploy/Dockerfile:43` 已用缓存与单 job。
- [上游 lib/zstd.h:1–8](https://github.com/meta/zstd/blob/v1.5.7/lib/zstd.h#L1-L8) 明确 BSD/GPLv2 二选一，分发选择 BSD-3-Clause，保留 Meta 版权、条件和免责全文（[LICENSE:5–30](https://github.com/meta/zstd/blob/v1.5.7/LICENSE#L5-L30)）。实施提交更新 `THIRD_PARTY_NOTICES.md` 的精确版本与选择；现有 `deploy/Dockerfile:52` 递归收集 LICENSE/NOTICE/COPYING，`:118` 放入 `/opt/codexone/licenses/swift/zstd/`，因此 LICENSE 与 COPYING 都会保留。`.github/workflows/release.yml:133` 从镜像导出 `licenses.tar.gz`；`scripts/verify_installation.py:307` 比对 checkout 身份与锁文件，另增断言 zstd/LICENSE 正文非空。独立分发仍附许可材料，不能只改清单就认定产物合格（`THIRD_PARTY_NOTICES.md:9`）。

## 启用与插入点

暂定仅在**最终传输为 HTTP、可信契约为 `codex-subscription`、方法 POST、路径 `/responses`、最终明文 UTF-8 编码大小 > 8 MiB** 时启用。包括 WS 超限/早期 1009 的合法单轮 HTTP 回退；实际 WS、原生 WS、独立 `/responses/compact`、Images、辅助接口、`responses` 第三方合约全部不压缩。按合约判断，不能凭 URL 为 HTTPS 就新增能力推断；现有合约解析见 `Sources/CodexOneAdapters/Downstream/ResponsesConfiguration.swift:30`、账号池固定值见 `Sources/CodexOneAdapters/Downstream/AccountPoolConfiguration.swift:92`。

配置预留在可信启动配置的 `ResponsesConfiguration`，由单身份与账号池共同装配：`upstreamRequestCompression`（`zstd` 默认、`off` 关闭），`upstreamZstdMinimumBytes`（默认 8,388,608，严格大于才启用；非负整数，非法值启动失败）。默认值对应现有 > 8 MiB 上传诊断门槛，优先覆盖已知大上传、避免小包的初始化成本；不是压缩收益的统计结论。待 **v0.26.9 上传诊断**按大小/耗时桶校准，本方案不读取运营数据、不编造压缩比，也不增加逐账号协商缓存或自动探测请求。

现有 `Sources/CodexOneAdapters/Upstream/HTTPResponseExecution.swift:172` 只编码一次为 Data，`:176` 将 UploadBody 作为 known-length stream。保留同一份编码 Data；在此选择明文 UploadBody 或 zstd 上传序列。压缩使用 level 3、checksumFlag=0、contentSizeFlag=0、nbWorkers=0，不设置 pledged source size；输入先 `ZSTD_e_continue`，最后以空输入反复 `ZSTD_e_end` 到返回 0（[lib/zstd.h:789–823](https://github.com/meta/zstd/blob/v1.5.7/lib/zstd.h#L789-L823)）。单帧、无字典、不声明原始大小，符合本任务确定的官方客户端参数。

压缩分支在可信上游头装配结束后设置唯一 `Content-Encoding: zstd`，删除原 Content-Length/Transfer-Encoding，AHC stream length 使用 unknown，由 HTTP/1 生成 chunked framing；Content-Type 仍为 application/json。明文分支保持现有长度。`Sources/CodexOneAdapters/Transport/ClientHeaders.swift:10` 的白名单不包含 Content-Encoding/Content-Length，不扩白名单；编码头由网关生成。P27 的有序 JSON 字节与未知字段保留规则保持，解压字节必须等于原最终编码，不重新解析或重排。第三方合约不继承此请求编码能力，也不改变入站解压或响应解压行为。

## 执行寿命、背压与内存

现有 `Sources/CodexOneAdapters/Upstream/UploadBody.swift:20` 每次拉取至多 64 KiB，只有消费 EOF 时调用 `upload.sent()` 与 `progress.requestSent()`；`Sources/CodexOneAdapters/Upstream/ExecutionBudget.swift:47` 从该边界启动 first 等待，`:81` 的任务组与 `HTTPResponseExecution.swift:76` 的总期限覆盖上传。**没有独立的上传超时配置**；压缩初始化、排队、CPU 与网络发送都计入原总期限，不延长或重置期限。zstd 必须在尾帧完全产出、最后一块被 AHC 背压消费后，下一次拉取才报告 EOF；不能在读完明文或 C 编码结束时提前报 sent。本机消费完成不表示上游收到；sent 只记一次，若提前拒绝时尚未 EOF 则记 interrupted。

`ZSTD_compressStream2` 在单线程模式同步执行，不能直接跑在 event loop（上游 `lib/zstd.h:803`）。数据服务持有专用 2 线程 NIOThreadPool；每个压缩上传持一个 permit，最多 4 个，线程池每请求至多一个在途分块 job，故最多 2 执行、2 排队，无额外 producer 任务或整包队列。每次 job 最多吃 64 KiB 输入、产一个有界输出块；若尚无输出，异步等待该 job 后检查取消再提交下一块，不在单 job 内遍历完整正文。Data 以只读 CoW 引用传入，`withUnsafeBytes` 只在同步 job 内借用，指针不跨 await；每请求 context 串行独占，不跨请求复用。

上传迭代器和所属执行共同负责关闭：父取消/总期限/上游提前响应/网络错误设置停止标记；排队 job 开始前检查，运行中的 C 调用不能强制中断，等当前有界块返回再停止。取消处理必须 await 已提交 job 后才释放 context/缓冲/permit，不得先 free 再让 worker 返回；未发 EOF 不标 sent。执行退出关闭上传 owner，即使 AHC 未再次调用 next 也能完成释放。服务停机先停准入、取消并等待执行及 job，再关闭池（接入 `Sources/CodexOneAdapters/Transport/ResponsesDataService.swift:305` 的收尾）。共享 executor 或 `Task.detached` 不能替代此 CPU 容量与监督。

**30 MiB 请求的新增峰值估算约 4 MiB，按 5 MiB/上传预留**：临时流式探针对重复文本及确定性伪随机字节各处理 31,457,280 字节，`ZSTD_sizeof_CCtx` 峰值均 3,663,377 字节（约 3.49 MiB），`ZSTD_CStreamOutSize()` 为 131,591 字节。加最多一份 64 KiB 输入转换（实现优先借用，按最坏计）、一个输出工作缓冲和一个待消费 ByteBuffer（各约 129 KiB），约 3.81 MiB，余量覆盖每请求小对象与分配器；另有进程共享的两 worker 线程栈/线程池常驻开销，尚未测量，冷启动并发 RSS 验收必须单列；5 MiB 不是进程 RSS 硬上限，也不含既有 JSON 树/原 Data/socket 缓冲。探针输出丢弃不累积；不可压缩输入输出 31,458,009 字节，不能假定总会缩小。禁止整包压缩 Data、`Array(data)` 或完整复制输入；需要产物大小时只能流式累加。

必须计入容量，不能把 `Sources/CodexOneAdapters/Transport/RequestBodyBudget.swift:8` 的 48 MiB 原文预算解释成总内存：它只在 > 8 MiB 时按整份入站正文计费（`:32`），且租约可能先于执行结束释放。保持其 32/48 MiB 行为，另在数据服务为压缩保留独立 **20 MiB 工作区预算（4 × 5 MiB）**，从初始化前一直持有至 worker 完全退出；包含小块和 C workspace。permit/预算不足在发送前选择明文，不等待、不新增 503；已开始压缩则不能切明文。该预算是新增开销约束，不修复原有 JSON/序列化内存压力；并发/RSS 实测超估算时阻止交付并调整实现或降低容量，不能用整包复制换吞吐。

## 失败与用量

| 观察 | 行为、健康与账本 |
| --- | --- |
| 响应生命周期事件前明确 HTTP 400/415 拒绝 | 沿 `Sources/CodexOneAdapters/Upstream/ProviderError.swift:17`、`:86` 返回现有脱敏拒绝；**明文回退 0 次**，不重选账号、不自动关闭压缩。状态本身不证明一定因 zstd，但足以按既有 U13 认定输出前拒绝，完整零用量、settled/failed，不计 unknown（`Sources/CodexOneAdapters/Upstream/ExecutionObservation.swift:73`、`:109`）。`Sources/CodexOneAdapters/Persistence/SQLiteAccountHealth.swift:145` 只惩罚认证/限流/不可用，普通拒绝不影响评分或冷却。 |
| 401/429/5xx | 沿既有认证/额度/不可用健康分类与用量证据规则；不当成压缩协商，不回退。 |
| 无可信终态，连接在响应开始前断开，含上传中/EOF 后 | 本机 sent、压缩成功或小体积都不是未执行证据；无重放，按既有 indeterminate/unknown；超时/取消保留原分类及 unknown/partial 责任（`ExecutionObservation.swift:17`、`:61`；U13）。 |
| 编码/worker 失败或已开始后超出资源界限 | 终止上传，释放并等待 job，不拼接明文、不重试；不惩罚账号。已准入但无明确拒绝/可信用量时保守保留 unknown，不新增猜测的零用量规则。发送前可判断的关闭、阈值、容量条件只选择明文。 |

16 MiB 是 **WS 最终未压缩 response.create 编码**的路由观察边界，仍按同一份编码字节判断（`HTTPResponseExecution.swift:94`、`UpstreamWebSocketBodyLimit.swift:6`）；不能用压缩大小让超限消息继续发 WS，也不新增 HTTP 16 MiB 上限。早期 1009 的一次 HTTP 回退与 zstd 的零次明文回退是不同规则；HTTP 回退失败沿现有收尾，不再回 WS。入站 32 MiB 上限不变。

## 上传诊断

扩展现有 `UploadBody.swift:35` 的 RequestUpload，结束时仍只记录一次 info **Upstream request upload**；沿 `Sources/CodexOneAdapters/Downstream/ProtocolFailureDiagnostics.swift:92` 的 > 8 MiB 原文门槛、独立 16 条/60 秒限额、transport/result/size_bucket/upload_duration_bucket。新增 `content_encoding=identity|zstd`、`wire_size_bucket`（≤1、≤4、≤8、≤16、≤24、≤32、>32 MiB 的固定互斥桶）、`compression_duration_bucket`（未压缩为 not_applicable；<1、1–10、10–100、100–1000、≥1000 ms）。原 `size_bucket` 是最终未压缩编码大小；wire 累加实际交给 AHC 的压缩块长度，interrupted 时仅为部分值，绝不冒充完整压缩大小；无 HTTP framing/TLS 字节。压缩耗时累计 worker 内初始化/编码/结束的单调时钟时间，不含排队和网络等待；上传总耗时仍含两者。内部精确计数只供分桶，不持久化、不记录正文、身份、URL、精确字节/时间或任意错误文本；WS 保留旧字段。

## 验收、迁移与待决

真实接口验收指**运行网关 binary，通过 HTTP/WS socket 访问 loopback 假上游**，不能只测 C helper。假上游读取真实 chunked/Content-Length、验证唯一编码头，流式解压到有界比较器，与关闭压缩时捕获的同一合成最终编码逐字节比较（含顺序、Unicode、工具字段、合成 base64），验证单帧结束、无 checksum、原始大小 unknown；截断帧必须失败。实现矩阵与提交边界见[任务](tasks.md)。

无数据库 schema/数据迁移；启动开关 `off` 是必要回退路径，重启后恢复明文、known length；不热切换正在上传的帧。旧二进制回退前删除新增配置字段，既有 schema v11 与历史 unknown 不改。不能因关闭开关而重放已失败请求。此开关只撤销本变更，不代表任何其他版本间原库回退均安全。

当前未决：v0.26.9 诊断校准阈值、原生 Linux SwiftPM/发行体积与许可证产物验收、并发 RSS 包络，以及真实订阅后端对 chunked zstd 的兼容性；这些都未在本次验证，真实客户端/订阅验收须另获授权。本次仅 macOS 依赖可行性与合成内存探针，不运行网关兼容验收，不发布。

## 相关文档

[任务](tasks.md) · [协议规范](../../reference/specs/protocol.md) · [用量规范](../../reference/specs/usage.md)
