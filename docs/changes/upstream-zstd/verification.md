# 上游 zstd 实现验证

记录 2026-11-03 当前分支的本机合成验收、资源测量与发布门禁；不包含真实订阅或部署验收。

## 平台与边界

macOS 27.2 arm64、Apple Swift 6.4.2、Python 3.9.6。所有请求、凭证占位与正文均为合成数据；只运行当前工作树的网关及回环假上游，没有 Linux 构建、SSH、部署、真实账号或 OpenAI 调用，没有 push、PR、发版或版本号/CHANGELOG 变动。

SwiftPM 精确固定 zstd 1.5.7 / `f8745da6ff1ad1e7bab384bd1f9d742439278e99`，其余依赖 revision 未变。初次完整 Git 历史下载过慢并中断，随后用当前工作树忽略目录中的官方固定 tag 浅镜像完成解析；锁文件仍为官方 URL，无本地镜像路径。已阅读随包 BSD LICENSE（Meta 版权、三项条件、免责）与 GPLv2 COPYING，分发选择 BSD；现有递归许可收集保留二者，安装检查增加正文断言。实际 Linux 镜像及 licenses.tar.gz 尚未验收。

## 验证命令与结果

- `swift test -j 4 --filter 'zstd|compressionConfiguration'`：首次 debug 构建通过，流式字节/帧参数、关闭竞争及 worker 拒绝的 3 项测试通过。构建期间新增配置测试文件，留给后续完整 backend 构建及执行，不把过滤成功当成配置覆盖证据。
- `python3 scripts/verify_upstream_zstd.py --binary .build/debug/codexone` 定向排错：阈值小于/等于/超过、off、第三方合约、JSON/SSE、四 permit 与第五请求明文降级、400/415/提前拒绝/再次415、401/429/500、上传断流、缺失终态/部分响应、首响应超时通过。首轮大块夹具漏计既有 JSON 斜杠转义，修正有界比较器预期；随后客户端等待与总期限等长引发夹具超时，改为留余量，不改变网关期限。
- 同一脚本的独立大块压力矩阵：慢读、完全不读、下游取消、服务停机均通过；单 attempt、派发次数、健康、账本、诊断及进程退出均有断言。
- macOS 默认 Xcode release 构建失败于 adapter 的 `primary.d` 依赖文件生成，未得到产物；改用项目提案已有的 native build system 构建实际 release 二进制，不修改编译器/分配器或 Linux 设置。`swift build --build-system native -c release -j 4 --product codexone` 通过（163.06 秒），产物 48,643,976 字节（未 strip）；紧接同配置无改动重建通过（SwiftPM 6.66 秒、命令墙钟 7.593 秒）；在 Xcode 单测后切回 native 的另一次重建重新编译依赖，耗时 152.22 秒，不把它当作热缓存命中。没有旧版对照二进制，不报告 zstd 专属二进制/镜像增量。
- `./scripts/verify.sh --backend` 只执行一次：文档、架构、格式与构建通过；Core 66、Adapters 281、Runtime 7 项通过，EndToEnd 83 项中的旧账号池大请求测试产生 20 条失败断言（一个参数化测试的四种组合），原因是合成上游尚未解压新正文。补齐有界流式解压后，`swift test -j 4 --filter oversizedWebSocketHTTPFallbackPreservesAccountAndHealth` 的四个用例通过；新增 `compressed415NegotiationKeepsPoolAccountAttemptBytesAndHealth` 两个用例通过，确认同账号、同 attempt、完全相同编码字节、零健康惩罚及再次415停止重发。没有重跑完整 backend 命令；继续执行首次因单测失败未执行的四个脚本分片。
- `./scripts/verify.sh --backend-scripts 1/4`、`2/4`、`3/4`、`4/4`：全部 40 个脚本通过，各分片脚本累计 227 / 333 / 139 / 131 秒。新 zstd 脚本为 62 秒，位于第 1 分片；最长第 2 分片未新增脚本，仍距 480 秒上限有 147 秒（CI 制品/SDK 等开销另计，本机耗时不是 CI 保证）。
- 最终 `swift test -j 4 --filter 'compressed415Negotiation|oversizedWebSocketHTTPFallback'`：2 项测试、6 个参数化用例通过。账号池用例是进程内真实 socket 服务夹具；独立网关 binary 矩阵使用合成单身份，不宣称真实订阅池已验收。
- `python3 scripts/check_docs.py` 独立检查通过（96 份）；完整 backend 内也执行了其自带文档检查。最终 fixture 格式检查、`git diff --check` 与新增内容个人路径/凭证形式扫描通过。

新增脚本归属第 1 分片，沿用四分片完整覆盖检查。现有 WS 大请求脚本增加流式解压与头/framing 检查，覆盖订阅 16 MiB 上下边界及 9 MiB 早期1009→HTTP 压缩回退；第三方与原生 WS 的边界保持原断言。新脚本只依赖验证工具的 libzstd 动态库进行解压，产品静态链接固定的 SwiftPM 库；验证工具镜像显式安装 libzstd1，不增加产品运行时包。

## 评审修复：200 响应早于上传 EOF

2026-11-03，在同一本机 macOS arm64 环境定向验证。AHC execute 在响应头返回时不保证上传结束，旧代码的无条件 close 会取消 zstd 的后续拉取；明文 UploadBody 继续由 AHC 拉取。现将压缩 owner 交回现有 exchange 持有，2xx 头后允许继续上传，EOF 或 exchange 退出主动 await close；非 2xx 立即停止。EOF 前保留 permit/工作区，close 仍等待已有 worker job 且只归还一次，没有新增任务或改变服务停机顺序。

`requestSent()` 仍与明文一样，在 AHC 消费尾块后拉取 EOF 时调用，未移到响应头或 C 编码结束处。早到首事件通过原 progress.note 启动 idle，后来的 EOF 不重置它；总期限继续覆盖上传。

本次实际验证：

- `swift test -j 4 --filter 'zstd|ExecutionBudgetTests|compressed415Negotiation|oversizedWebSocketHTTPFallback'` 通过：Adapters 6 项（含新增 EOF 前持有/EOF 后归还、重复 close，以及原有首响应/早到事件计时测试）；EndToEnd 2 项、6 个参数化用例。测试构建更新当前工作树 debug 网关。
- `python3 scripts/verify_upstream_zstd.py --binary .build/debug/codexone` 完整定向矩阵通过。新增约 28 MiB 合成 base64 请求：上游只读第一小块即发 200/chunked SSE 头及 response.created；客户端确认在上游未收完前取得事件，再允许上游继续读取并逐字节比较解压数据，帧结束后发 response.completed，客户端和账本均成功；off 对照同样成功。
- 新增该场景的客户端 RST 取消、上游中途断开、上游提前结束响应体用例：没有成功终态，账本保留 unknown，取消确认为 client_cancelled。每个早响应场景后，同时阻塞四路后续上传，全部仍使用 zstd，释放后均成功，确认四个 permit 全部归还；off 对照后续均为 identity。原有非 2xx/415、慢读、静默、总期限、取消及停机矩阵仍通过。
- `python3 scripts/check_docs.py` 通过；提交前差异与新增内容检查通过。

夹具调整：EOF 现在即可归还工作区，高压缩率正文可能完全进入本机缓冲，不能靠上游未读来持有 permit；容量用例与四路回收探测改用难压缩正文，单路约 9 MiB，以免与 48 MiB 入站预算混淆。调试中分别发现旧容量夹具假设失效、过大的并发正文触发入站预算，以及下游 SSE 含 event 行，均只修正夹具。本次没有运行可选 RSS 矩阵；下方数据是修复前的历史测量，新的难压缩并发夹具需重新测量，不能将旧值视为修复后容量验收。

本次未跑完整 backend、release/RSS、Linux 构建或真实客户端/提供者；现有 Linux、真实上游兼容与内存发布门禁仍未完成。只使用当前工作树、当前分支及合成回环服务，未访问部署、订阅或 OpenAI，未 push、开 PR 或发版。

## 内存发布门禁

使用 `python3 scripts/verify_upstream_zstd.py --binary .build/release/codexone --memory-output <临时结果文件>`，实际 release 网关、独立合成账本与回环上游，每个样本新建进程；三类 30 MiB 输入为重复文本、固定 seed 伪随机可打印文本及固定 seed 合成 base64，每类 off/zstd 各三次；另测四路略大于 8 MiB 正文加第五请求（总入站小于 48 MiB），off 与 zstd 各三次。假上游按有界块流式解压并与同一最终编码比较，绝不累计完整压缩产物。网关输入引用原编码 Data，工作缓冲/输出块均至多 64 KiB；没有新增完整输入或压缩副本。

采样只统计网关 PID，macOS 用 `ps` RSS、Linux 脚本支持 `/proc`，约 10 ms 加采样调用耗时一次；全程峰值另取 `wait4` 的内核 `ru_maxrss` 高水位，避免漏掉采样间的短暂 JSON 峰值。记录启动基线、全程峰值、请求头后峰值及假上游收完后的短暂保留峰值；进程共享两 worker 在线程池启动时已存在，off 与 zstd 使用相同池。短暂保留为 250 ms，仍在原首响应期限内。RSS 含既有入站、JSON/编码 Data、AHC/NIO/socket 与分配器保留，不能把 48 MiB 入站预算当成总内存，也不能把单次差值解释为纯 C workspace。

下表为三次全程峰值（MiB），每对 off/zstd 使用相同合成编码；小数是测量值换算，不是内存硬限制。

| 输入/并发 | off 三次峰值 | zstd 三次峰值 | 配对净增量三次 |
| --- | --- | --- | --- |
| 30 MiB 重复文本，单路 | 175.797 / 170.656 / 168.938 | 165.438 / 165.547 / 166.344 | -10.359 / -5.109 / -2.594 |
| 30 MiB 伪随机文本，单路 | 209.297 / 217.797 / 221.250 | 198.109 / 196.750 / 196.422 | -11.188 / -21.047 / -24.828 |
| 30 MiB 合成 base64，单路 | 217.250 / 224.000 / 197.562 | 198.516 / 198.625 / 197.312 | -18.734 / -25.375 / -0.250 |
| 四路压缩 + 第五路明文，对照五路 off | 201.062 / 197.609 / 198.438 | 205.453 / 207.641 / 205.500 | +4.391 / +10.031 / +7.062 |

启动基线为 18.062–18.281 MiB，双方均包含相同的两 worker 池；共享线程相对于完全没有线程池的进程增量没有单独隔离。请求头后/收完后的采样峰值与内核全程峰值相差不超过约 0.08 MiB。合成文本的 JSON 转义与提供者准备字段算入最终编码，所以 30 MiB 指合成内容规模，不是精确 wire 长度。

单路没有观察到超过 5 MiB 的净峰值增加；四个压缩 owner 同时存在时最大净增量 10.031 MiB，低于 20 MiB 总预留，无需据此扩大预算。单路的负差不代表压缩不分配内存，也不证明 C workspace 减少：两条路径的拉取节奏、AHC/NIO 缓冲和分配器保留不同，且既有 JSON/编码峰值有波动；它是实际进程的净差，不能当作纯 C context 大小。既有探针约 3.49 MiB C workspace 仅作解释，不能替代这些进程数据。

AHC 1.36.2 的 `AsyncAwait/Transaction.swift` 逐块调用 async next 并交给 executor，只有 paused 时等待恢复 continuation；暂停来自 channel writability，而非远端收包。网关自身每 owner 只保留一个 worker job、一个 64 KiB 输出工作区和一个返回块；AHC/NIO、TLS（本次回环无 TLS）及 socket 仍有各自缓冲，EOF 不代表远端消费完成。完全不读与慢读的真实进程用例验证期限和回收，不能由压缩率推断背压。

本机净增量在预留内；5 MiB/上传、4 上传/20 MiB 继续作为新增工作区预留。Linux 进程总包络及共享线程开销未验收，内存仍为发布门禁，当前不授权发布。

## 未完成的验收

原生 Linux SwiftPM、优化产物/镜像层增量与许可归档、Linux 并发 RSS/768 MiB 包络仍须 CI 或授权环境验收；未在本机交叉构建 Linux。真实上游 chunked zstd 与官方整包 Content-Length 的差异仍是兼容风险，`off` 为回退路径。阈值仍为暂定 8 MiB，未读取运营数据，未标记诊断校准完成。

取消/EOF/worker 排队和执行竞争有定向与真实进程覆盖，但未穷举每个 C 调用指令或强制注入 libzstd 分配失败；不把这些结果当成实际客户端、提供者兼容或生产容量承诺。既有入口正文持有及 glibc 设置未修改。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [协议](../../reference/specs/protocol.md) · [容量](../../reference/specs/operations.md)
