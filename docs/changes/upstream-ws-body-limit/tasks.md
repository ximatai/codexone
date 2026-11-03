# 上游 WS 正文上限任务

跟踪合成验收与发布前由维护者执行的真实上游验证。

## 前一轮预检验收

- [x] 发送前一次编码及 16 MiB 判断，安全的一轮 HTTP 回退
- [x] JSON/SSE/native 确定性错误、无未知执行或账号惩罚
- [x] 本地真实 binary 合成边界、续接、拒绝、取消、账本及字节序验证
- [x] 阅读固定 revision 官方客户端源码并记录处理行为
- [x] macOS build、docs、定向验证及完整 backend 一次
- [ ] 发布前维护者真实上游/HTTP 大小验收（本任务不执行）

2026-11-03，macOS arm64 本地合成验证：`swift build -j 12`、`python3 scripts/check_docs.py`、`verify_upstream_ws_body_limit.py`、`verify_json_order.py` 均通过；账号池定向 Swift 测试的成功/413 × 状态头/正文四组通过。真实 binary 矩阵使用单身份本地 fake，账号池使用生产服务与合成账号的进程内端到端测试；不把后者声称为真实 binary 的账号池验收。大图片字段为不经 codec 解码的合成不透明字节，只验证传输，不验证真实图片/模型接受。

官方源码 revision 与 413 上层仍可能重试的限制见[兼容说明](../../reference/compatibility.md#大请求错误的官方客户端源码核查)。`./scripts/verify.sh --backend` 一次完整通过：428 个 Swift 测试、38 个后端脚本（含新增矩阵），格式/文档/架构检查通过。无 Linux 构建、真实账号/提供者请求或部署验收。

规范及回退影响见 [proposal](proposal.md)。

## 本次补全

- [x] 早期真实 1009：独立 HTTP 单轮同账号回退；原生/续接 413、完整零用量；其他关闭与生命周期后 1009 不变
- [x] reader 在入队前建立生命周期屏障；metadata 不提交后再回退；原生拒绝后同客户端 socket 后续小 turn 可用
- [x] 保持 32/48 MiB 限制；四档大小桶及 ingress/budget 拒绝诊断
- [x] 真实 binary 合成失败矩阵与 macOS RSS 测量
- [x] 本次最终 backend 验证：完整命令仅一次、中断及补验结果如实记录如下

本次定向验证：macOS build、两方言完整边界矩阵及更新后的 `--failures-only` 通过。真实进程覆盖 JSON/SSE 早期 1009 成功/HTTP 413、metadata 后回退、原生初始/后续 turn 拒绝及同 socket 后续小 turn、Responses 续接 413、created 后 1009、1011/EOF、metadata 后非1009的 SSE 顺序、取消、严格一次回退、账本/用量/字节序。两个 Swift reader/桶边界测试通过；两账号进程内端到端的成功/413 × 状态头/正文四组分别覆盖预检及 metadata+1009，所选账号不变、无其他账号重试、双方健康不变、两个 attempt 均 settled。真实 binary 为单身份 fake，不能将两账号进程内测试声称为真实 binary 账号池验收。Codex subscription HTTP 的 `previous_response_id` 保留原有参数拒绝，已允许该字段的 Responses 方言验证实际 1009 续接拒绝。

## macOS RSS 指示性测量

2026-11-03，macOS 27.2 arm64，`swift build -j 12` 的 debug binary；`python3 scripts/measure_upstream_ws_body_limit.py --binary .build/debug/codexone`。每组新建真实网关进程，fake provider 持有 HTTP 回复，`ps -o rss` 约每 20 ms 采样（另加 ps 启动耗时），覆盖解析、预检编码、HTTP 回退、持有及结算；仅统计网关进程，排除 Python 客户端/provider。每组先采样 0.5 秒空闲；正文为精确入站 JSON UTF-8 大小，WS 帧另有协议开销；32 MiB 请求恰好到 ingress 上限，两路 24 MiB 恰好占满 48 MiB 共享预算。

| 负载 | 空闲峰值 RSS（MiB） | 请求阶段峰值 RSS（MiB） | 采样数 |
| --- | --- | --- | --- |
| 单个 17 MiB | 20.69 | 109.70 | 84 |
| 单个 32 MiB | 20.62 | 181.67 | 124 |
| 两个并发 24 MiB | 20.61 | 248.64 | 105 |

三组空闲峰值最大 20.69 MiB。均成功且仅走 HTTP fallback，无超限 WS 派发；32 MiB+1 声明长度返回 `request_too_large`，两路 24 MiB 仍持有 lease 时第三路 9 MiB 返回 `capacity_exhausted`，未新建 attempt；实际日志断言 `reject_ingress`/`over_32_mib` 与 `reject_budget`/`at_most_16_mib`，WS 编码桶也断言。四档桶精确边界另有 Swift 测试。采样可能漏过短暂峰值，RSS 包含分配器保留内存，不是精确 live heap 或最低内存需求；仅供 macOS 参考，未测 Linux、容器/768 MiB 限额、release binary、真实图片 codec、真实客户端和真实上游接受范围，不据此提高任何限制。

从生命周期可识别的正文分配：HTTP reader 的原始 `Data` 持有到 route 结束；解析后的 JSON 字符串树与原始正文同时存在，保序 scanner 另临时持有全量 `[UInt8]`，Foundation decoder 还有解析缓冲；WS 预检的 ordered writer 数组和输出 `Data` 在编码时可同时存在，但超限 WS 编码在 HTTP 正文分配前丢弃。HTTP 编码阶段，原始正文、JSON 字符串树、ordered writer 增长数组与结果 `Data` 可重叠；数组容量可大于有效长度，先前释放的页面也可能仍计入 RSS。两个并发请求各自持有这些资源，共享预算只计入站正文，不覆盖所有副本。未做 heap snapshot，因此不能将某个 RSS 峰值精确归给某一个副本。

删除了 HTTP 执行中 `ByteBuffer(data: encodedData)` 的整份 eager 复制：直接交给已锁定版本 AHC 的 `.bytes(Data)`，由它按约 4 MiB chunk 转换；仍保留已验证的有序 `Data` 和相同 Content-Length/正文，不改编码、预算或拒绝边界。字节矩阵及完整 backend 复验覆盖此路径。未进行重写 JSON codec 或内存预算语义的扩大重构。

## 本次最终验证与执行限制

macOS arm64，最终 `swift build -j 12` 通过；收尾修正后 `swift test --skip-build --no-parallel -j 12` 全部 **431 个 Swift 测试**通过（66+83+7+275）。最终格式 lint、文档/架构检查、diff 检查通过。真实 binary 的最终 `--failures-only` 两方言均通过：每方言在原生 socket 上连续 8 次交替直接/metadata 1009，收到 413 后立即发送小 turn，不等待账本，均成功；413 现在等待旧会话及其命令 reader 结束后才发送。另有极大 continuation 声明长度（Int.max，加上已有 1 字节片段）的单元测试，确保诊断大小计算饱和，不溢出、不分配声明大小的正文。

`CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` **只启动一次，没有一次性跑完**：当时 430 个 Swift 测试及前 11 个后端脚本已通过；收尾审查加固原生 reader 交接时，错误地并行重新链接可执行文件，导致 `verify_response_finish.py` 启动下一组网关子进程时出现临时 binary 缺失（FileNotFoundError），不是应用协议断言失败。没有再次运行完整 backend 命令。固定复制验证用 binary 后，从该失败脚本起逐个执行原入口中余下的 **27 个脚本，全部通过**；合计 38 个后端脚本均已覆盖。加固后的原生失败矩阵、相关 12 个 Swift 定向测试、诊断溢出测试及最终全部 431 个 Swift 测试另行通过。完整命令中断仍保留为执行局限，不声称整条命令一次通过。

RSS 测量对应 HTTP 内存优化后的代码；随后修正只涉及原生 WS reader 交接与拒绝诊断的溢出保护，未改变被测 HTTP 正文路径或限制。无 Linux 构建、部署、真实订阅/提供者请求；发布前真实上游接受验收由维护者执行，仍为本任务之外的发布门槛。

## 相关文档

[协议规范](../../reference/specs/protocol.md) · [贡献指南](../../../CONTRIBUTING.md)
