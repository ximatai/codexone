# 运行责任与边界设计

本页说明 Rust 网关的运行责任。行为不变量和具体容量以[能力规范](../reference/specs/README.md)为准。

| 责任 | 实现位置 | 持有的状态与结束责任 |
|---|---|---|
| 连接与请求 | `gateway/src/listener.rs`、`gateway/src/ws/` | 监听任务管理连接容量、正文读取、写入进度及关闭。连接负责取消自己的 I/O，已准入执行仍须收尾。 |
| 准入、归属、结算与恢复 | `execution`、`storage` | 执行 worker 持有 SQLite writer 与准入票据。原子事务校验 Key、账号及容量，提交绑定后才可向客户端暴露 ID。启动恢复先收敛遗留 intent，关闭时排空 writer 并释放实例锁。 |
| 账号池与会话路由 | `account-pool`、`gateway/src/managed.rs` | 准入在同一 writer 事务复核候选状态；会话亲和、续接来源和端点健康有各自限额与期限。关闭时取消等待。 |
| 授权、刷新与被动额度观察 | `identity-runtime` | 共享工作各自拥有并发容量和网络任务。等待者可独立取消；服务停止时取消共享任务并处理已有持久刷新责任。 |
| 窗口预热和重置卡 | `quota-jobs` | 各任务持有定时器与执行状态。预热复用执行准入并持久化窗口屏障；重置卡先存 intent，未知结果沿原请求 ID 核对。 |
| 管理请求与会话 | `admin`、`governance` | 管理路由校验会话、Origin 与 CSRF，再通过业务入口读写。会话撤销同时撤销关联的实时连接。 |
| 首页实时观察和用量 | `gateway/src/overview_live.rs`、`usage` | 实时服务持有 viewer、采样任务和有界邮箱，用量读独立 WAL 连接。发布活动不等待 viewer；退出收回 viewer 资源，关闭读侧后再结束 writer。 |
| 存储水位、快照与离线维护 | `execution/src/reserve.rs`、`maintenance`、`gateway/src/online_backup.rs` | writer 复核关键空间并保留收尾优先级。在线快照持有只读连接并自行退出，离线维护使用独占实例锁与持久恢复屏障。 |

连接状态归连接，持久执行状态由条件事务决定。网络和管理 DTO 不进入账本持久模型。SQLite 事务完成准入、绑定或结算等单个原子命令，跨网络等待不持有事务。证据不足时保留执行责任，恢复期间不重放。

核心账本的写入配额须与可选任务隔离。短时加密上传暂存由 `gateway/src/body_staging.rs` 管理，独立核算字节额度，清理随请求或进程结束。核心账本、暂存空间和备份的安全边界见[运行规范](../reference/specs/operations.md)。

网关入口组织停收、连接 drain、管理与身份任务结束、只读连接清理、writer 排空和锁释放。时钟判断应使用适合语义的来源，账期和持久时间使用 UTC，耗时和截止时间使用单调时钟。

验收选取可直接观察的责任交接，包括断连与持久收尾并发、归属失败不暴露响应 ID，以及有未完成交接时的退出与重启。当前入口见[验证说明](../development/verification.md)。旧实现细节见 [Swift v0.26.53 的运行边界](https://github.com/ximatai/codexone/blob/65624e4c45ee1f86560b7640abe42bec31a25f60/docs/architecture/ownership.md)。

## 相关文档

[文档导航](../README.md)
