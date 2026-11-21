# 验收

记录合成预热对照、拒绝路径和待核对的真实上游边界。

- [x] 2026-11-21，macOS arm64，以 `002e3f2` 分别构建 Swift 和 Rust（该提交 Swift 源码及依赖与 v0.26.53 一致）。通过临时回环端口和数据库运行合成 Codex subscription WebSocket 上游。两边都通过省略或空数组 output。旧 Rust 拒绝 null、带响应归属的 metadata 和 WebSocket 耗时帧，Swift 三种均通过。这三个形状都能复现同一个 Rust 错误码。
- [x] 修正后，省略、null 和空数组均通过。连接元数据先于 created 原样下发，之后为 in_progress、completed；显式 null 在下游保留。预热缺失用量时账本为 `unknown/succeeded`，用量为空。随后在同一上游 socket 通过预热 ID 发起正式生成，再用上一正式响应 ID 续接，两次均为 `settled/succeeded`、完整用量。
- [x] 修正后，非空数组、畸形 output、生成 delta、带响应归属的 metadata、耗时帧及其他非生命周期事件仍拒绝，账本为 `unknown/failed`。每个客户端 create 恰好派发一次；错误帧无私有原因，日志只增加对应固定分类。测试使用合成头、内容及 ID 验证这些字段未写入日志。
- [x] Swift 对照还会接受带生成消息的非空 output 和畸形对象 output。Rust 按 P15 保留这两种形状的拒绝。
- [x] Rust WebSocket crate 全部 27 项测试、`verify_websocket.py` 及 `verify_client_protocol.py --expect-provider-eof` 通过。更新后的共享 WebSocket 用例在旧 Rust 的 null 预热复现失败，在 Swift 与修正后的 Rust 完整通过，覆盖单独预热模式、缺失用量、同连接续接、并发 lane 隔离、拒绝和断开后不重放。
- [x] 只读观察中，持久账本出现预热失败，且同一窗口出现 `warmup_websocket_timing` 固定分类。两者使用聚合核对，实际帧字段、顺序及逐请求关联尚未取得。
- [x] 固定 Swift 与 `56ef39f` Rust 对照合法耗时帧、顺序、预热终态及同连接生成。
- [x] 验证有限耗时封套、夹带业务数据拒绝、仅耗时帧后 1009 保留未知，以及缺失用量与不重放。
- [x] 新候选的只读观察仍出现预热失败和 `warmup_websocket_timing`。固定公开源码和上游测试已确认嵌套遥测的用法，真实封套仍未知。
- [x] 对照官方测试封套、未来遥测字段以及明确业务字段的根位置；保留终态、续接、用量及无重放测试。
- [ ] 在透明转发候选中核对自然预热的账本和固定分类。

## 耗时帧对照

2026-11-21，macOS arm64，使用独立临时回环端口、SQLite 和合成 Codex subscription WebSocket 上游。Swift 源码和依赖在 `002e3f2` 与 `56ef39f` 一致。使用同一 provider 流，仅打开或关闭耗时帧。下表简写 `response.metadata`、`response.created`、`response.in_progress`、`response.completed` 的共同顺序。

| 上游差异 | Swift 下游 | Rust `56ef39f` 下游 | 候选 Rust 下游 |
| --- | --- | --- | --- |
| 无耗时帧 | metadata → created → in_progress → completed | 同 Swift | 同 Swift |
| created 前插入数值耗时帧 | metadata → timing → created → in_progress → completed | metadata → error | 同 Swift |
| in_progress 后插入数值耗时帧 | metadata → created → in_progress → timing → completed | metadata → created → in_progress → error | 同 Swift |
| 完成后连接空闲时送无归属耗时帧 | 正常终态，空闲帧丢弃 | 同 Swift | 同 Swift |
| in_progress 后插入带生成输出的同名帧 | 透传夹带的输出并继续至 completed | error，拒绝 | error，拒绝 |

各成功预热为 `unknown/succeeded`，`usage_json` 为空。同一个上游连接随后按预热响应 ID 正式生成，再从新响应 ID 续接，两笔均 `settled/succeeded`、用量完整。旧 Rust 的两个合法耗时反例在生命周期终态之前失败，账本均为 `unknown/failed`。候选对带嵌套业务数据、响应/用量字段或非数值耗时的同名帧也返回 `invalid_upstream_warmup`，账本为 `unknown/failed`，各拒绝用例只有一次上游派发。

Swift 通过通用 WS 路由和 provider 观察处理耗时帧，预热下发处没有对应的生成内容校验。Rust 原有 `Turns::observe` 已决定 lane 和处理风险，但预热守卫随后以非生命周期事件为由拒绝，读取提前停止，终态未入账。候选在该守卫核对辅助帧封套，事件分类器继续承担生命周期、进展、可绑定对象及用量语义。合法耗时帧只报告可能已处理，在没有生命周期证据时不会记录首个响应观察。仅有该帧后收到 1009，仍为执行未明，单次派发。旧共享预热夹具覆盖空输出和续接，耗时夹具则只覆盖普通生成，缺少两者的交集。

Rust WebSocket crate 28 项、共享 `verify_websocket.py`、`verify_client_protocol.py --expect-provider-eof` 和 `verify_text_contract.py --case extension` 通过。共享预热夹具保留开关对照，在旧 Rust 第二轮明确复现失败，Swift 和候选两轮均通过。

真实样本只提供同窗固定原因分类，未确认具体封套、序列或与该条账本的逐一关联。自然预热若继续报同一分类，仍需判断是否存在其他成员、其他时间字段或顺序差异。若出现新的拒绝分类或仍缺终态，则需核对此后帧或连接结果，单凭合成对照无法确定兼容边界。

## 透明转发对照

2026-11-21，macOS arm64，原生 WS 使用合成订阅上游。固定 Rust `24d67c2` 只在打开新形状时出现 `warmup_websocket_timing`，Swift 与透明转发候选均完整下发官方 `timing_metrics` 的合成结构、两个 `critical_path` 候选层级、旧 `duration_ms` 和独立的未来字段。共享用例在 created 前后注入不同结构，逐帧比对客户端收到的 JSON；嵌套 `response`、`usage`、`headers`、`output` 和 `safety_buffering` 沿遥测原样送达。合成预热完成且用量为空时账本为 `unknown/succeeded`；同一 socket 上以预热 ID 生成，随后以正式响应 ID 续接，两笔均完整结算，各客户端 create 派发一次。

候选继续拒绝带顶层输出、响应/用量、headers 或 safety_buffering 的活动预热 timing，已有归属的晚到 timing 如携带顶层业务字段则被隔离，不影响已结束预热。单测验证透传计入累计预算且不刷新有效进展、不建立响应归属。合成断线对照中，未收应用事件直接收到 1009 保持既有 413 和完整零用量证据；只在 1009 前插入合法嵌套 timing，客户端先收到 timing，随后收到 `execution_indeterminate`，账本为 `unknown/failed` 且无用量。两组均单次派发。

Rust WebSocket crate 29 项、共享 `verify_websocket.py`、`verify_client_protocol.py --expect-provider-eof`、`verify_text_contract.py --case extension` 和文档/架构检查通过。更新的共享用例在 `24d67c2` 的嵌套 timing 阶段明确复现失败，在 Swift 与候选上完整通过。真实字段、真实事件顺序和部署后恢复仍待自然样本核对。

## 相关文档

[变更提案](proposal.md)
