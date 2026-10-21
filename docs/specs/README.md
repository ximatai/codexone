# 能力规范

这些文件是当前行为规范，不是完成清单；实现进度查 STATUS。编号用于任务和测试映射。仅放可验收要求，动机见 ADR/架构。

| 能力 | 文档 |
|---|---|
| 协议与生命周期 | [protocol](protocol.md) |
| 身份、Key 与授权 | [identity](identity.md) |
| 用量与未知执行 | [governance](usage.md) |
| 正文恢复缓存 | [recovery-cache](recovery-cache.md) |
| 持久化与发行恢复 | [operations](operations.md) |
| 管理产品面 | [control-plane](control-plane.md) |

规范新增/改变必须对应 docs/changes 的提案与验收记录。详细状态机参考 [当前架构](../architecture/ARCHITECTURE.md)；文档矛盾需同步修正。
