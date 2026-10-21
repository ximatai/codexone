# 能力规范

这些文件是可修订的行为工作草案，不是完成清单；实现进度只查 STATUS。编号用于任务和测试映射。仅放可验收要求，动机见 ADR/架构。

| 能力 | 文档 |
|---|---|
| 协议与生命周期 | [protocol](protocol.md) |
| 执行状态机、屏障与 WS 生命周期 | [execution-lifecycle](execution-lifecycle.md) |
| 身份、Key 与授权 | [identity](identity.md) |
| 用量与未知执行 | [governance](usage.md) |
| 正文恢复缓存 | [recovery-cache](recovery-cache.md) |
| 最小完整结果恢复候选契约 | [recovery-contract](recovery-contract.md) |
| 持久化与发行恢复 | [operations](operations.md) |
| 管理产品面 | [control-plane](control-plane.md) |

规范新增/改变必须对应 docs/changes 的提案与验收记录。完整行为细则与状态机归本目录；[架构](../architecture/ARCHITECTURE.md) 只解释组织/取舍并引用规范。条款的“必须”约束按该草案实现的行为，不表示边界永远不可调整。
