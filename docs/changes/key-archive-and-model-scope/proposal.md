# Key 归档与“全部模型”范围

日期：2026-11-01。用户要求：(1) 已不再使用的 Key（如部署冒烟测试 Key）不希望一直出现在列表中，但不能影响用量统计和审计；(2) 旧服务中“不限模型”的 Key 迁移后被写成当时配置的显式模型清单，与原意不一致，新增模型时不会自动获得。本提案修改 [Key 治理](../../development/key-governance.md)、[控制面](../../specs/control-plane.md) 与 [身份](../../specs/identity.md) 中相关约束。

## 一、Key 归档

- 新增“已归档”状态标记，存于现有 `managed_keys.metadata_json` 的 `archivedAtUnixSeconds`（UTC 秒，缺省/旧记录为 null），不改 schema。
- `PUT /api/keys/:id/archive`（JSON `revision`）：仅 `enabled=false` 的 Key 可归档；启用中的 Key 返回 409 `key_enabled`，须先停用。已归档重复归档返回 409。
- `PUT /api/keys/:id/unarchive`（JSON `revision`）：清除归档，Key 保持停用，不能一步恢复为可用。
- 已归档 Key 拒绝启用、轮换、策略/显示名/到期修改，返回 409 `key_archived`；须先恢复。认证路径不变（已归档必为停用）。
- 归档/恢复均为 revision CAS、写审计（`archive`/`unarchive`），消耗普通审计容量；不新增撤销预留。
- `GET /api/keys` 新增查询参数 `archived`：缺省/`false` 只返回未归档，`true` 只返回已归档；分页游标按同一过滤。元数据返回可空 `archivedAtUnixSeconds`。
- 用量、明细、进行中请求、审计及 keyOptions 继续关联归档 Key 的显示名与主体；keyOptions 增加 `archived` 布尔供界面区分。attention 不为已归档 Key 产生 Key 类提醒。
- 归档 Key 仍计入 256 个 Key 总数上限。不提供硬删除，不自动清空。

## 二、“全部模型”范围

- Key 策略 `models` 可为 `null`，表示对话模型跟随网关当前配置的全部对话模型；`imageModels` 在 `imageGeneration=true` 时可为 `null`，表示跟随全部已配置图片模型。字段仍须显式出现：创建/更新请求缺 `models` 仍拒绝，`[]` 仍表示无对话模型（仅图片 Key）；能力字段缺省的既有“按关闭处理”规则不变。`imageGeneration=false` 时 `imageModels` 为 null 与 [] 等价。
- 有效目录/准入/执行使用当前配置的全部模型（与显式清单一样仍与上游配置取交集）；配置新增模型后立即对此类 Key 生效，移除后立即失效。策略版本包含 null 取值。
- 管理 API、元数据、离线导入清单接受并原样返回 null；revision CAS、审计、轮换不变。`export_key_trial.py` 对源 `allowed_models` 为 null 的 Key，在 approval 选择 `"source"` 模型模式时输出 `models: null`（图片按源推导规则不变）。source 模式另传 `--configured-models-file`（当前配置对话模型 ID 的 JSON 数组），用于非 null 源清单求交；缺少清单拒绝。配置“立即生效”指当前加载配置生效后，无需再改写 Key；沿用既有配置加载/重启入口，不新增热重载。
- 管理界面：对话模型与图片模型分别提供“全部模型（跟随配置）/指定模型”，列表与详情显示“全部模型”。

## 兼容与回退

旧二进制不能表达全部模型的 null 语义：`models: null` 解码失败，`imageModels: null` 按旧缺省规则变成 []（启用图片生成时校验失败）；也会忽略归档标记（归档 Key 仍为停用，安全）。回退前须将“全部模型”Key 改为显式清单；该前提写入回退说明。

## 不变项与排除

不改变启用 Key 的认证、限额、账号池调度与计价；不新增按模型的细分限额；不做硬删除、批量归档或自动归档。

## 验收

- 单元/API：归档仅限停用 Key、重复归档、恢复后仍停用；已归档拒绝启用/轮换/改策略/改显示名/改到期；CAS 冲突；审计记录；列表默认过滤与 `archived=true` 分页；keyOptions/用量仍可显示归档 Key 名称；attention 跳过。
- 模型：`models: null` 的目录、准入、Responses 图片工具组合；配置增减模型后即时生效；缺字段拒绝、`[]` 语义不变；策略版本随 null 变化；导入往返保留 null；旧策略无 null 时行为不变。
- 前端：归档/恢复确认流程、已归档筛选（回收站）、默认列表不显示；模型范围切换与显示；组件测试与浏览器操作检查。
