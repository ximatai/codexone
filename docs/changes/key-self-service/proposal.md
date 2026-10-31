# Key 自助查询

拟为自己的设备 Key 提供隔离的只读自助用量查询。

## 问题

Key 持有者想知道自己今天用了多少、离限额还有多远、什么时候到期，只能问管理员。管理端口仅监听本机，持 Key 的人访问不到。

## 范围

### 后端

1. **自助状态接口**：在网关数据面新增 `GET /codexone/key/status`，用该 Key 本身认证（与 Responses 相同的 `Authorization: Bearer`；不接受查询参数传 Key，不接受 Cookie）。返回：
   - principal、状态（enabled/disabled/expired）、到期 UTC 秒（可空）；
   - 五项本地限额（null 表示不限）与当前 UTC 日窗口内的已用请求、预算已用（估算）、active、unresolved；
   - 最近 7 个 UTC 日的每日请求、失败与估算费用（与 U14 同口径，只含本 Key）。
   - 不返回 Key ID 以外的内部标识、其他 Key、账号、请求明细、正文或凭证。
2. **认证语义**：仅托管 Key；禁用或已到期的 Key 仍可查询自身状态（只读，不准入），以便持有者知道原因。错误 Key 与 Responses 相同返回 401，不区分“不存在”和“格式错误”。
3. **资源边界**：只读查询复用用量只读 reader 的容量与扫描预算，繁忙 429；响应 no-store。认证失败按现有数据面行为处理（Key 熵足以抵御猜测，不新增 IP 限速；如部署在反向代理后，沿用代理层限速）。

### 前端

1. 网关在 `GET /codexone/key` 提供一个独立静态页（与管理台同一构建、同样 CSP，不含管理代码与会话）：输入 Key 后查询并展示状态、限额进度条、今日用量和 7 日趋势。
2. Key 只保存在页面内存中，刷新即清除；不写 localStorage/sessionStorage/URL，不记录到日志。提供“清除”按钮。

## 不做

- 持有者自助修改限额、轮换或续期；登录体系或多用户。
- 请求明细与导出（避免把内容相关的元数据暴露给持 Key 的人）。

## 验收

- 接口：有效/禁用/到期/错误 Key、轮换后旧 Key 401、只返回本 Key 数据、繁忙 429、no-store、Query 参数或 Cookie 携带 Key 被拒。
- 页面：CSP 下无违规；Key 不进入存储/URL；错误与空数据状态；1440×900 与窄屏。
- 规范同步（control-plane、usage），完整后端与前端验证、Linux verification。

## 相关文档

[文档导航](../../README.md)
