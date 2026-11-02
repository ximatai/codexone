# 会话路由与元数据验证

记录本次修复的合成协议验收与平台边界。

[跨项目复盘](review.md)发现的续接来源与 WS 载体缺口已按透明优先契约修复；下方新增验收为最终实现证据，旧通过记录不替代新场景。

## 透明优先修复的最终验收

2026-11-02，macOS arm64、Apple Swift 6.4，全部为合成服务：

- `CODEXONE_BUILD_JOBS=4 ./scripts/verify.sh --backend` 通过：414 项 Swift 测试（66 + 81 + 7 + 260）、34 个后端验收脚本。严格格式、生命周期、文档、架构检查包含在内。
- 本轮复审修复先通过定向 7 项，再重新完成上述全量验收；未派发的未知来源与畸形状态仍分类为 accountUnavailable/invalidRequest。
- 实际 HTTP/WS 证明：已知来源固定账号，来源禁用与未知 token 均拒绝且无额外 intent；HTTP→WS 显式状态进入消息 metadata、握手不携带本轮状态。
- HTTP SSE 与 WS 上游仅以 metadata 事件返回状态时，下游 JSON/SSE 均能返回首状态，后续回送固定来源账号；HTTP SSE 已提交头后收到状态也保留事件和来源，不补写已提交头。原生首消息兼容握手、后续不自动注入，跨固定连接 owner 的消息被拒绝。
- 原始状态头的超长、重复及逐跳声明明确拒绝；32 个 x-codex 头容量内优先保留状态。Responses、compact、Images、辅助入口的超长状态均在派发前返回 400，无 intent。
- WS 首轮畸形/冲突状态返回标准 400 error 帧，拒绝记录各一条，无上游连接或 intent；畸形握手状态返回 HTTP 400 且不升级。
- Key 隔离、跨账号 token 冲突墓碑、TTL、容量、父子线程独立位置与 process seed、重复/冲突载体有回归；未知状态不会变成对象授权或 draining 资格。
- 固定来源账号在另有健康候选时仍正常刷新；凭证刷新期间新增/到期的冷却在实际选择点读取；Key 撤销/到期优先于冷却拒绝。
- 429 保留账号级保护，辅助 5xx 只隔离端点；辅助切换不影响主 token 来源。真实控制期限、断连、代理/TLS、迁移切回与隐私脚本通过。
- PR 独立复审发现的三项 P2 已分别修复并新增上述协议回归；此前凭证刷新候选修复继续由全量验收覆盖。

无数据库或 Key 格式迁移。token 来源为有界内存记录，重启/TTL/淘汰后拒绝未知来源；不提供透明恢复。未调用真实订阅，本文记录本机验收，本次追加修复的 Linux CI 以 PR 检查为准；未发布部署。普通事件与请求内容按既有契约透传，不推断辅助 HTTP body 的身份语义；不保证提供者缓存命中率。

## PR #75 客户端契约复审

2026-11-02，macOS arm64、Apple Swift 6.4.2，仅使用合成服务与数据：

- `swift test -j 12 --filter 'turnState|responseMetadata|metadataOnlyReturnsState|httpMetadataAfterSSE|detachedWebSocketMetadata'` 通过：10 项测试，含 HTTP/WS 和 JSON/SSE 参数组合。
- `python3 scripts/check_docs.py` 通过；随后仅运行一次 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend`，418 项 Swift 测试（66 + 82 + 7 + 263）及 34 个后端验收脚本全部通过，包含严格格式、文档与架构检查。
- 注入单调时钟证明成功查找可持续跨越一小时并刷新容量淘汰顺序；未命中不创建来源或刷新其他记录，冲突墓碑不因查找续期，1024 项上限不变。
- 字符串与非空数组首元素使用相同校验；空数组、首元素非字符串、空值、超长和非法控制字符均忽略，不扫描后续元素。
- 账号池 HTTP SSE 与 WS 桥接逐个记录同次执行中的两个数组状态（先 codex.response.metadata，后 response.metadata），两者回送均固定原账号并返回 200；HTTP 返回头始终保留首状态。首输出后收到的 SSE 状态仍记录来源。
- 原生 WS 终态后转发的数组 metadata 事件也记录来源，客户端收到后明确回送可继续同账号执行。single 与账号池共用此事件转发路径；可信 single 不要求池来源记录。

未调用真实订阅或提供者端点，未运行 Linux 构建，未部署或推送；真实客户端与提供者兼容性仍需单独验收。

## 复测与异常记录

- 早期代理验收曾在状态/耗时合并断言失败，原输出未标明具体分支；增加固定场景、状态、耗时诊断，没有放宽断言。独立代理复测及随后完整后端验证均通过，初始原因尚未复现。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [协议](../../reference/specs/protocol.md) · [客户端约定](../../reference/compatibility.md)
