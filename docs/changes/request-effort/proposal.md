# 调用记录显示推理强度与服务档位

日期：2026-10-31。修改[用量](../../specs/usage.md)用量明细字段与[管理面](../../specs/control-plane.md)用量接口。

## 问题

用量明细看不出每次调用的推理强度（reasoning effort），也看不出是否使用了倍速等服务档位（service tier）。两者直接影响订阅窗口额度消耗，旧服务的请求日志记录了这两项。

## 行为

- 准入时从客户端请求中读取 `reasoning.effort`（Responses）与 `service_tier`，作为非秘密元数据写入现有 admission JSON：值须匹配 `[a-z0-9_-]{1,32}`，否则记为 `other`；缺失记为 null（表示未指定、由上游按模型默认）。不改 schema，不影响转发内容与准入判定。
- 若上游终态事件带回实际 `service_tier`，写入 outcome JSON 的 `actualServiceTier`（同样校验）。
- 原生 Images、预热与压缩：无对应字段时为 null。
- 用量明细与“最近请求”返回可空 `reasoningEffort`、`serviceTier`、`actualServiceTier`；用量页明细表新增“推理”列（未指定显示“默认”，并在模型目录有默认值时以灰字注明，如“默认 · high”），详情中显示请求与实际服务档位；筛选增加推理强度。
- 历史记录无此字段显示为“—”，不补写。现有 admission JSON 增加可缺省的 requestMetadataRecorded 标记，区分历史缺字段与新请求未指定；API 的三个可空参数显式返回 null。
- 推理强度筛选仅精确匹配合法记录值，default 仍是普通合法值，不作为未指定的哨兵；模型默认说明由受保护 options 的 defaultReasoningEfforts 从可信目录元数据提供。

## 验收

- 解析：各合法值、缺失、非法/超长 → other、非字符串；不改变上游请求体。
- 实际档位读取与缺失。
- 接口字段与筛选；前端列、默认值注明、历史“—”。
- 规范同步；`verify.sh --backend`、`verify.sh --web --chrome`；主 Agent Linux verification。
