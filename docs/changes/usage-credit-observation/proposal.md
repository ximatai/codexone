# 额外使用积分的只读观测

先核实 CodexOne 能否从现有账号额度读取取得余额证据，再决定是否在账号详情展示。该余额对应 ChatGPT 支持功能的额外使用积分，与套餐窗口、订阅重置卡、API 平台积分及本地 Token 账本分别呈现。[OpenAI 积分说明](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-plus-pro)

## 数据来源

- CodexOne 已使用同一订阅身份调用 `GET /backend-api/wham/usage`。现有读取保留账号隔离、超时、响应上限和可选返回身份核对。当前解析只保留套餐窗口及重置卡可用数量，忽略额外使用积分。
- 官方 Codex 源码的同一端点模型包含可选的 `credits`。其中 `has_credits` 与 `unlimited` 是布尔值，`balance` 可缺省、可为 null，提供时是字符串。官方客户端也认识生成响应头和限额事件中的积分快照。这些是客户端源码证据，尚无各套餐响应形状与更新时序的实测。[官方额度客户端](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/backend-client/src/client/rate_limit_resets.rs) · [官方积分模型](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/codex-backend-openapi-models/src/models/credit_status_details.rs) · [官方限额事件与响应头解析](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/codex-api/src/rate_limits.rs)
- Codex Switch 已在同一额度读数中解析字符串余额，并附本地观测时刻。该实现提供交叉证据，其合成验证无法证明指定账号会返回该字段。[Codex Switch 余额读取](https://github.com/joshp123/codex-switch/commit/af99a7c34cd51014a4d81ce7cda76fd869bc5b26)

## 候选范围

若实测支持，再扩展现有只读额度读取和管理账号详情。复用观测任务与账号身份，不新增轮询。余额缺失、null、非法值、无限额和明确为零分别处理，积分子字段异常不影响套餐窗口。观测时间标作本地读取时间。首版评估是否沿用最近一次额度快照保存有界字段，先核对旧读者、快照、恢复及向下回退约束。未经实测不更新现行用量规范。

请求在本地结算只说明执行和用量有证据。积分余额是账号级读数，账户共享功能、并发、补充积分和异步结算都可能影响差值。余额变化不会写进单请求账单，观测字段也不参与准入、自动消费、重置卡选择或路由。

## 验收

1. 在获得指定账号的只读验证授权后，沿已有身份和额度入口做少量独立读数，并与同账号的官方用量页对照。仅记录是否提供字段、类型和一致性，不保存真实账户余额、响应正文、账号身份或凭证。
2. 另行确认有可能消耗积分的受控试验。选择确已触顶、重置未临近、无其他活跃客户端的账号，分别核对请求前后额度窗口、积分余额和官方用量记录。隔离无法确认或余额延迟刷新时保留未知。单次观察的结论只适用于当次条件。
3. 若进入产品实现，再以合成数据验证缺失、零、无限额、异常子字段、旧记录、账号隔离与陈旧读数。通过窄屏和桌面浏览器检查后更新能力规范。

## 相关文档

[任务](tasks.md) · [用量规范](../../reference/specs/usage.md)
