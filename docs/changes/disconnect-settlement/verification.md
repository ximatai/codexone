# 验证：下游断开时补发中断并续读终态

日期：2026-10-31。环境：macOS arm64；仅本机合成 socket、账号和用量数据。

## 实现与覆盖入口

- 补发复用原连接 owner、turn 状态和续读任务；dispatch 标记保存在原 turn 中，下一轮重置。只发送 `type`、`response_id` 和非默认 lane 的 `stream_id`，不携带客户端额外字段，不新增准入。
- `verify_client_protocol.py`：无客户端中断时断开，补发一次、终态按输入5/输出3/估算8结算，outcome 保留 `cancelled`/`client_cancelled`；8条续读保留全部连接槽，结束后全部8槽可重新取得。
- 同一入口覆盖 EOF、error、10秒无终态、未知事件后无终态：unknown、不重放、释放本地资源后新请求成功。unknown 的治理暴露继续按 U03/U06 保留，不视为退款。
- 客户端已中断不重复补发；同 lane 排队请求在断开后不 dispatch；未发 create 与已终态断开不补发。请求已 dispatch 但没有响应身份时，在同一期限内等到生命周期 ID 后定向补发；始终缺身份时有界取消。
- 多 lane 中一条补发失败不提前终止另一条续读；非默认 lane 的中断定位字段逐项检查。运行时停止在5秒内取消已进入续读的任务；原执行期限2秒时不延长至10秒。
- Swift turn 测试检查未 dispatch、缺身份、已中断、已终态及复用下一轮的资格；账号池 socket 测试覆盖握手中/在途断开、运行时取消与原期限。
- 原有 `verify_protocol.py` 和 `verify_images.py` 保留 HTTP/SSE 与原生 Images 断开回归；HTTP→WS 桥接仍不进入原生下游续读路径。
- 没有新增日志；合成入口断言未知头只记录名称、已知头不告警，正文、头值与凭证不进入日志。

## 实际验证

| 命令 | 退出码 | 耗时 | 结果 |
|---|---|---|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 521.35秒 | Swift 261项与全部后端合成脚本通过；严格格式、架构、构建与后端入口内的文档检查通过 |
| 定向 Swift（命令如下） | 0 | 26.50秒 | 5项定向测试通过（其中1项含3个参数用例） |
| `python3 scripts/verify_client_protocol.py --binary .build/debug/codexone` | 0 | 26.91秒 | 补发/取消结算、失败/不重放、容量回收、lane隔离、停止与短期限全部通过 |

定向 Swift 命令：

```sh
swift test --disable-sandbox --no-parallel -j 12 --filter 'Interrupt|interruption|disconnectSettlement|poolNativeWebSocketDisconnectAndRuntimeCancellation'
```

Swift 四个测试 target 分别为40、44、3、174项。独立 `python3 scripts/check_docs.py`：退出0，0.05秒；206份 Markdown、本地链接与变更结构检查通过。

首次定向协议入口退出1，30.73秒：合成上游等待某条 lane 的终态放行时阻塞了唯一请求 reader，无法读取另一条 lane 的中断；测试设施改为带结束/等待路径的延迟终态 worker 和串行 writer，重跑该失败入口通过。首次依赖下载较慢的预备构建由执行者中止（130）；从已有 SwiftPM 缓存复制锁文件指定 commit 到本 worktree 的忽略构建目录后，`swift build --disable-sandbox -j 12 --skip-update` 通过，锁文件未改。

## 2026-10-31：Linux 握手失败的本机复核与修复

- 修改前在 macOS arm64 debug 二进制下运行协议入口，并保持28个 `yes` CPU负载进程：第一次退出1，23.15秒；上游发现同一响应被中断两次，随后“只补发一次”断言失败。负载进程均由 `finally` 终止并等待退出。
- 另一次负载诊断中，空闲探测握手均在约1—8毫秒成功，满槽握手则仅等到客户端超时。检查锁定的 NIO typed upgrader 证实：`shouldUpgrade` 返回nil后不重放已消费的升级请求头/结束，原HTTP回退没有可拒绝的请求。改为在升级回调内写完既有503 `capacity_exceeded` envelope并关闭；Swift检查完整head/body/end、request ID及关闭，实际socket检查1秒内明确拒绝。
- 握手卡住还可由测试日志管道背压独立复现。旧脚本仅在网关退出后读取 `stdout=PIPE`，每次探测的未知前缀头warning会填满小管道，阻塞同步日志写入和事件循环。本机使用3072字节未消费日志socket模拟小缓冲，出现5秒握手超时；在修复后的网关上使用旧脚本且不启用日志捕获时，仅开始消费日志，不手动释放槽位或重启网关，4.6毫秒内重新拨通，随后续跑其余断言通过（诊断总耗时31.08秒）。这证明不能把同类握手卡住全部归为空槽异步释放慢；本轮未运行Linux，原Linux失败仍需主Agent复验。
- 协议脚本现在为每个网关进程持有一个持续读取并等待结束的日志worker，最多保留128 KiB、溢出继续排空并报错；保留全部脱敏断言。结算场景实际日志超过8 KiB，直接覆盖小管道填满条件。失败拨号显式关闭socket，条件等待仅重试503；握手超时、EOF或意外状态直接失败，不再被重试吞掉。全部8槽重取共享3秒上限，单次拨号最多1秒，无放宽续读上限。
- 中断资格改为在原turn锁内原子领取，且在writer挂起前完成；客户端控制与补发竞争只能一个发送，同一在途turn重复中断不再写上游。Swift用64个并发领取者验证唯一胜者；实际socket覆盖立即关闭客户端中断后的单次发送。
- 未发现空闲连接被 `permitSettlement()` 保留10秒：未发create的探测连接不进入 `serveTurns`；已结束会话的activity为0，关闭后立即结束owner。`.awaitingIdentity`轮询受关闭后的同一个10秒竞速期限与原执行期限约束，两条10秒子任务并行、先完成后取消另一条，不是串行20秒。无需修改这三处生命周期逻辑；新增连续三轮全8槽关闭/重取和耗时样本，仍验证活跃续读保留槽、10秒无终态释放、原2秒期限及运行时取消。
- 定向Swift命令 `swift test --disable-sandbox --no-parallel -j 12 --filter 'concurrentClientAndSettlement|websocketHandshakeRejection|disconnectSettlementUses|lateInterrupt'`：退出0，10.77秒，4项通过。

本轮实际验证：

| 命令 | 退出码 | 耗时 | 结果 |
|---|---|---|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 515.69秒 | Swift 271项（40/44/3/184）、严格格式/架构/构建和全部后端合成入口通过；结算日志17935字节，8组全槽重取6.08—12.36毫秒 |
| 定向Swift（本节命令） | 0 | 10.77秒 | 4项通过：完整握手拒绝、并发唯一中断资格、迟到确认和当前turn资格 |
| `python3 scripts/verify_client_protocol.py --binary .build/debug/codexone`（28个 `yes` 持续施压，14逻辑核，连续5次） | 全部0 | 27.56 / 27.57 / 27.32 / 27.97 / 27.61秒 | 5/5通过；全部负载子进程终止并回收；每次日志17935字节 |

负载下40组全8槽重取样本：最小13.35毫秒、中位14.69毫秒、P95 20.75毫秒、最大34.57毫秒。样本从发起重取计时至8个握手全部成功，包含本地槽位释放等待及握手开销，是释放延迟的上界，并非仅测单个锁操作。活跃续读的10秒超时仍由同一脚本实测，不能用上述空闲释放样本替代。

## 兼容边界与承接

不做上游能力探测，复用既有原生 WS `response.interrupt` 能力假设；提供者拒绝、断开或不返回可信终态时保守保留 unknown，不重试生成。未增加新的配置或客户端握手要求。

旧客户端无需修改消息格式，已关闭连接不会收到额外内容；可见差异在于停止后的用量可能从 unknown 变为按实际结算，outcome 仍为客户端取消；本地连接槽最多保留10秒，高并发下新连接可能暂时遇到容量限制。真实上游是否支持、是否及时给出可信终态尚需主 Agent 按授权验收。

未运行 Docker/Linux、真实订阅、OpenAI、部署、推送或 PR；Linux 与真实 Desktop 停止验收由主 Agent 承接。STATUS 按任务授权由主 Agent 维护。
