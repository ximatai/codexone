# 额外使用积分的只读观测

CodexOne 在账号详情展示只读余额，真实账号对照是上线验收项。该余额对应 ChatGPT 支持功能的额外使用积分，与套餐窗口、订阅重置卡、API 平台积分及本地 Token 账本分别呈现。[OpenAI 积分说明](https://help.openai.com/en/articles/12642688-using-credits-for-flexible-usage-in-chatgpt-plus-pro)

## 数据来源

- CodexOne 已使用同一订阅身份调用 `GET /backend-api/wham/usage`。现有读取保留账号隔离、超时、响应上限和可选返回身份核对。现有读取同时解析套餐窗口、重置卡可用数量和额外使用积分。
- 官方 Codex 源码的同一端点模型包含可选的 `credits`。其中 `has_credits` 与 `unlimited` 是布尔值，`balance` 可缺省、可为 null，提供时是字符串。官方客户端也认识生成响应头和限额事件中的积分快照。这些是客户端源码证据，尚无各套餐响应形状与更新时序的实测。[官方额度客户端](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/backend-client/src/client/rate_limit_resets.rs) · [官方积分模型](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/codex-backend-openapi-models/src/models/credit_status_details.rs) · [官方限额事件与响应头解析](https://github.com/openai/codex/blob/c875667eb837663697d5ffa32d375043434e73b4/codex-rs/codex-api/src/rate_limits.rs)
- Codex Switch 已在同一额度读数中解析字符串余额，并附本地观测时刻。该实现提供交叉证据，其合成验证无法证明指定账号会返回该字段。[Codex Switch 余额读取](https://github.com/joshp123/codex-switch/commit/af99a7c34cd51014a4d81ce7cda76fd869bc5b26)

## 实现范围

本地实现扩展现有只读额度读取和管理账号详情，真实读数对照仍是上线验收项。复用观测任务与账号身份，不新增轮询。余额缺失、null、非法值、无限额和明确为零分别处理，积分子字段异常不影响套餐窗口。观测时间标作本地读取时间。沿用最近一次额度快照保存有界字段，既有 schema 和备份格式不变。旧记录缺字段时仍可读取，旧程序可忽略该字段，重新写入快照时会丢弃该字段。仅账号详情 DTO 暴露余额。

请求在本地结算只说明执行和用量有证据。积分余额是账号级读数，账户共享功能、并发、补充积分和异步结算都可能影响差值。余额变化不会写进单请求账单，观测字段也不参与准入、自动消费、重置卡选择或路由。

## 验收

1. 在获得指定账号的只读验证授权后，沿已有身份和额度入口做少量独立读数。将账号详情接口返回的余额与同账号的官方用量页对照。若详情接口缺少余额且无法判定原因，再在认证后的额度响应归一化前做一次性探测。仅输出字段是否存在、类型及是否一致，不保存真实余额、响应正文、账号身份或凭证。如使用探测，试验后移除。
2. 另行确认有可能消耗积分的受控试验。选择确已触顶、重置未临近、无其他活跃客户端的账号，暂停该账号的重置卡自动化、空闲预热与其他可能改变额度的操作，分别核对请求前后额度窗口、积分余额和官方用量记录。事先限定观察次数及总等待时间，隔离无法确认或到期仍无稳定读数时保留未知。单次观察的结论只适用于当次条件。
3. 以合成数据验证缺失、零、无限额、异常子字段、旧记录、账号隔离与陈旧读数。同时检查窄屏和桌面浏览器展示。

## 相关文档

[任务](tasks.md) · [用量规范](../../reference/specs/usage.md)
