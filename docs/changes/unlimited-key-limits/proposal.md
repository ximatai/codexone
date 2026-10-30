# Key 无限额

日期：2026-10-30。用户要求：旧服务（CodexLB）的 Key 可以不设任何限额，迁移来的 Key 及新建 Key 也应能明确选择“不限”。本提案修改 [Key 治理](../../development/key-governance.md) 与 [摘要导入](../../development/key-import.md) 中“limits 必须为五个正整数”的约束。

## 新契约

- Key 策略 `limits` 仍须显式给出五个字段 `requests`、`active`、`unresolved`、`budgetMicros`、`unresolvedMicros`；每个字段可为正整数（≤10¹²）或 `null`。`null` 表示该维度对此 Key 不设上限；缺字段仍拒绝，不以缺省代表不限。
- 准入时跳过取值为 `null` 的 Key 维度检查；全局、主体与上游身份限制、执行容量、账本、预留与 unknown 责任照常记录与执行。用量与未结暴露照常统计和展示。
- 管理 API（创建/更新）、离线导入清单与导入后的元数据接受并返回 `null`；revision CAS、审计、轮换语义不变。策略版本包含 `null` 取值。
- 管理界面：每个限额可选择“不限”；列表/详情/用量页显示“不限”而非数字。
- 导出转换 `export_key_trial.py`：approval 的 `limits` 可写 `"source"`，表示按源 Key 实际限额推导——源 Key 没有任何限额记录时五项均为 `null`；源存在任何限额记录时，该条目以 `source_limits_unsupported` 隔离（不静默放宽或猜测换算）。显式数值 limits 的现有行为保持。

## 兼容与回退

存储仍为现有 JSON 元数据，不改 schema。旧二进制无法解码 `null` 限额：回退到旧版本前，须先把所有不限 Key 改为显式数值，否则旧版本拒绝启动或拒绝这些 Key；该前提写入回退说明。

## 不变项与排除

不新增按模型/时间窗的细分限额（CodexLB 的 limit_type/window 等价迁移另立变更）；不改变全局容量、账号池调度与计价。

## 验收

- 单元：五个字段各自 `null` 时跳过对应检查，其余维度仍生效；缺字段/负数/超限拒绝；策略版本随 null 变化。
- API/socket：创建、更新、导入接受 `null` 并原样返回；不限 Key 在超过旧上限的请求数下仍准入；全局限制仍拒绝。
- 导入：`"source"` 推导无限额；源有限额记录时隔离。
- 前端：编辑器选择“不限”、列表/用量显示，单元测试与浏览器操作检查。
