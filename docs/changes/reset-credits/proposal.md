# 订阅限额重置卡

## 共识与目标

维护者已批准：按托管订阅账号实时列出重置卡；管理员确认后使用指定卡或提供者默认卡；可按账号开启到期前自动使用，默认关闭。遵守 I19/I20 的可信订阅身份、代理、独立有界 HTTP owner，A10—A13 的管理认证、CSRF、容量与安全 DTO，以及 U10 和 O15/O16 的观察、持久屏障、迁移及恢复契约。

## 行为与责任

- Core 定义卡、设置、消费结果与持久命令；Adapters 解析提供者协议、执行 SQLite 事务和管理 API；Runtime 拥有周期、每账号单飞、容量和关闭。
- GET `/api/accounts/:id/reset-credits` 实时读取，响应最多 64 KiB、最多 128 张卡；仅返回 id/type/status/grantedAt/expiresAt/title/description/availableCount 和本地设置、待核对标记及最近结果。未知 type/status 可读但不可自动使用，时间必须为 RFC 3339，null 到期不猜测。提供者正文不持久化。
- POST `/:id/reset-credits/consume` 接受可选 creditID；服务产生 UUID，在发送前事务保存 intent 及审计位置。每账号只能有一个待核对 intent；超时、断流、取消、未知代码或本地结果提交失败均保留原请求 ID。下一次同卡/默认核对及重启周期仅重发原 ID，其他卡冲突，绝不以新 ID 猜测重试。已知结果 reset/nothing_to_reset/no_credit/already_redeemed 才结束 intent；未知代码映射 unknown，不保存原文。
- 确认框列卡名与到期；nothing_to_reset 明确“当前没有可重置的用量，卡未消耗”。待核对时只提供确认核对原操作。GET 不触发消费；管理会话未知结果锁仍适用。
- PUT `/:id/reset-credits/settings` 保存 autoUseBeforeExpiry（默认 false）、leadHours（1—168，默认 24），携账号 revision CAS；与其他账号变更共用修订。
- Runtime 单一顺序周期每 30 分钟扫描最多 64 账号；配额观察发现可用卡时触发提前扫描（每账号仍受 30 分钟周期门槛），无积压任务。与手动操作共享最多 4 个工作、每账号一个工作；网络复用配额 client 四容量、5 秒总期限、无重定向/自动重试。
- 自动操作仅 enabled/ready，先核对原 intent；否则选 available 且 now < expiresAt <= now + leadHours 的最早到期卡（同时间按 id），每账号每周期最多一张；无到期卡跳过。nothing_to_reset 下周期重试。关闭接纳后取消并 await 网络和持久收尾，再关闭库。
- 每次消费尝试写独立有界审计（最多 4096 条，先占位 unknown，完成原位更新），不占账号刷新/禁用预留。未知结果、自动 reset、连续三次失败产生账号 attention；日志仅账号 id、卡 SHA-256 摘要及固定结果码，不输出卡原文或提供者正文。

## 存储、迁移与回退

采用 schema v11：新增每账号设置/单一 intent 状态及重置卡审计。复用 quota JSON 无法可靠提供 intent 原子屏障、审计预留和旧程序拒绝，因此选择显式 schema。v10→v11 持实例锁，先私有一致性 pre-v11 备份，再事务建表与升版本；旧版本迁移继续完整保留既有升级语义。新库初始化 v11，普通启动拒绝旧库，旧二进制拒绝 v11，禁止原地降版本。

备份包含设置、intent 和审计；restore 保留未知 intent，关闭自动使用，沿用账号必须重授权与 restored_unreconciled 屏障。旧快照不证明快照后消费未发生，恢复后须先人工核对提供者记录，不能把恢复的卡/用量当余额恢复。回退必须停服、保留 v11 与新增审计/未知操作证据，独立恢复升级前备份并核对快照后操作，不能直接覆盖数据库。

## 验收与范围

仅合成提供者/socket/数据库/浏览器；验证列表空到期、未来类型/状态、边界及超限；四个消费码、未知码、丢响应后相同 ID already_redeemed；认证/CSRF/容量；注入时间的提前窗口、排序、每轮一张、nothing_to_reset、默认关闭、非 ready 跳过、关闭取消；v10 迁移和备份恢复；前端列表、确认、结果、设置及桌面/窄屏。按 brief 运行文档、前端全套和最后一次 backend 验证，如实记录环境限制。

不包含官方客户端 `/usage` 菜单透传（可后续单独评估）、按用量压力自动使用、真实订阅验收、部署、SSH、Linux 镜像构建、push 或 PR。
