# 管理台首页“需要处理”提醒

日期：2026-10-31。用户决定：不做邮件或外部推送，只在首页以醒目方式标出需要管理员关注的事；排在管理台基础层阶段 2 之后、[用量分析](../usage-analytics/proposal.md)之前。也是将来 Nginx 切换后人工观察的主要入口。

## 问题

提前刷新失败、额度将尽、Key 到期、错误率突增、客户端出现新协议等情况分散在各页面或只在日志里，管理员不主动翻就发现不了。

## 范围

### 后端

`GET /api/attention`（管理员，复用 A10/A11 认证、来源、no-store 与容量契约），只读汇总现有数据，不新增 schema，不新增后台任务。返回 `items` 数组（最多 50 条，按严重度再按时间排序）与 `generatedAtUnixSeconds`。每项：`kind`（固定枚举）、`severity`（critical/warning）、`subjectType`（account/key/system/protocol）、可空 `subjectID`、可空 `subjectName`、`detail`（固定枚举或数值，不含自由文本错误）、可空 `sinceUnixSeconds`。

| kind | 条件 | 严重度 |
|---|---|---|
| account_requires_auth | 账号授权状态 requires_auth | critical |
| account_auth_uncertain | auth_uncertain | critical |
| account_cooldown | 存在执行健康冷却 | warning |
| quota_high | 主或次窗口已用 ≥ 90%（新鲜观测） | warning（≥ 98% critical） |
| quota_stale | 额度观测失败或超过新鲜期 | warning |
| key_expiring | 启用 Key 在 7 天内到期 | warning |
| key_limit_near | 启用 Key 当日请求或预算已用 ≥ 90% | warning |
| unresolved_executions | 存在 unknown/待核对执行 | warning |
| error_rate_high | 最近 60 分钟已准入 ≥ 20 且失败率 ≥ 10%（不含客户端取消） | critical |
| storage_pressure | 现有低盘保护进入告警或拒绝状态 | critical |
| client_protocol_extension | 本进程启动以来出现的未知 WS 控制消息类型或未知 `x-codex-*` 头名（仅名称与首次时间，最多 32 个，进程内有界集合，重启清空） | warning |

阈值为命名常量；所有判断复用现有只读 reader/观测快照，单在途、扫描预算与取消门禁同用量查询。数据源读取失败时该类返回一条 `attention_source_unavailable`（warning），不当作“无异常”。

### 前端

- 首页顶部“需要处理”区：有项时醒目显示（critical 红、warning 琥珀，图标 + 一句中文说明 + 跳转到对应页面/抽屉）；无项时一行“暂无需要处理的事项”。随首页自动刷新。
- 左侧导航在有 critical 项时显示小红点。
- 不做“忽略/已读”状态（无持久化）；状态消失即条目消失。

## 不做

- 邮件、webhook、手机推送；历史告警记录；可配置阈值。

## 验收

- 每个 kind 的触发与不触发边界、排序与 50 条截断、数据源失败、鉴权/来源、繁忙 429；协议名称集合有界、只含名称。
- 前端：各严重度展示、跳转、空状态、自动刷新；1440×900 走查。
- 规范同步（control-plane、operations）、完整后端与前端验证、Linux verification。
