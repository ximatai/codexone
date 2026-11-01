# 运行责任与边界设计

职责分配按共识执行，可随实际功能验证调整。行为不变量见规范，本表只定义执行位置和调用方向。

| 责任 | 业务 owner / 类型位置 | Task/资源 owner | 调用与结束责任 |
|---|---|---|---|
| 准入、归属、结算、核对 | Core/Application（Domain 值类型） | 单次执行协调器；后台任务由 Runtime 监督 | 调事务端口，返回语义结果；不调用全局 Runtime 服务 |
| 账号池选择 | Core/Application 的单次 AccountPoolGateway | 既有 finalizer ticket 先覆盖候选准备；无独立后台任务 | 调归属/原子选择端口；Adapters 在同一 DB 事务选择并准入，已准入只由 finalizer 收尾 |
| 连接与 WS lane | Adapters/Transport | 每连接 supervisor，受总容量监督 | 调 Core 执行用例；拥有 channel，取消后关闭并 await 网络任务 |
| finalizer | Core/Application 定义结算/合并规则 | Runtime 监督有限 worker 与预分配 ticket | worker 调核心用例，核心调事务端口；禁止反向等待连接 |
| 刷新与身份验证 | Core/Application/Identity | Runtime AccountRefreshSupervisor 的有界队列/共享任务 | 通过上游/凭证端口执行；等待者取消不取消共享刷新，关闭信号取消网络并 await/收敛 intent |
| 被动额度观察 | Core/Application 定义凭证/观察端口 | Runtime AccountObservationSupervisor 单飞有界工作；Adapters 独立 HTTP owner | 等待者取消不取消工作；关闭 await，提交核对身份/版本，不占刷新网络容量 |
| 用量查询 | Core/Application/Usage 查询值与端口 | Adapters 单一只读 WAL reader/专用队列 | 一个在途快照、有总预算/取消；入口先关闭 reader 再关闭主库，不占 writer 队列 |
| SQL 原子操作 | Core/Application 定义命令端口 | Adapters/Persistence 有界 DB 执行 | 一次命令一个事务；不跨网络持有，不向核心返回 SQL row |
| 恢复授权与代际 | Core/Application/Recovery | Runtime 监督缓存 worker；Transport 只交内容 | 先查核心归属/当前策略，后调缓存端口；restore 用例协调新 generation/清理 |
| 未知关闭与保留 | Core ExecutionMaintaining，Adapters 原子汇总/清理 | Runtime ExecutionMaintenanceSupervisor 单一顺序 owner | await 每轮最多 100 条后等待 60 秒；非 normal 暂停，关闭 await 后再关 DB |
| 存储压力与周期观测 | Core 定义水位与观测端口，Adapters 采样/储备/SQLite | Runtime StorageMonitor 单一顺序 owner | await 一次维护再等待；writer 队列复核，关键收尾保留，先停 monitor 再关闭 DB |
| 启动、drain、维护锁 | Core 定义所需端口/结果 | Runtime | 入口组装；启动恢复前不开放准入，关闭有顺序且有期限 |
| 管理 API | Core 的管理用例 | Adapters/ControlPlane 的请求/会话 | DTO 转应用命令；不直接改共享字典/DB |

## 端口和可变状态

端口由消费者一侧在 Core/Application 定义；具体 NIO/AHC/SQL/Vapor/密钥实现只在 Adapters。Runtime 只依赖 Core 的用例/寿命端口，Adapters 不依赖 Runtime；CodexOne 入口持有二者并组装。若真实依赖要求反向 import，应先调整端口归属，不用全局 service locator 绕过。

attempt 的执行状态由执行协调器单一修改；持久真相由条件事务决定；连接状态属于连接，身份刷新状态属于共享刷新协调器。actor 不是事务，也不是取消所有权；不得让一个全局 actor 串行所有 token、DB 与加密。

## 原子命令与两种存储

核心事务端口以准入、归属提交、结算和核对等业务原子操作为边界，不预建逐表通用 repository。它们在适配器内一次事务校验/更新必要多表，条件失败返回类型化结果。具体库/驱动按实际 API 验证，不能为了未来 PostgreSQL 牺牲当前条件事务。

RecoveryStore 只处理加密内容、顺序/完整性、代际条件写与删除；授权/重复执行判断在核心恢复用例。核心库与缓存库无联合提交保证；核心绑定失败必须停止 ID 暴露，缓存失败只使该恢复记录不可用。

核心写入/最终化保留不可被缓存占用的执行配额；缓存加密/批写/清理有独立字节、条目、worker 与批次上限。具体线程池与调度实现按实际负载确定。磁盘水位以实际文件/WAL/在途增长衡量，在耗尽前停止缓存，再停止新准入；“清缓存”不能代替预留核心结算空间，磁盘真满按核心故障恢复，不能保证仍写得下。

## 验收要求

持久执行验证 DB 不可写＋断连＋finalizer 满时无循环等待、意图可恢复；协议用提供者差异夹具证明客户端 DTO 不穿入上游/账本；缓存验证加密/清理饱和不抢走核心配额、删除代际及 restore 次序。测试要测所有权，不为表中每格制造一个抽象类。

## 相关文档

[文档导航](../README.md)

墙上时间由 Core 的 `WallClock` 值提供，生产入口显式组装 `.system`，需要时间决策的 owner 在构造时接收。公开构造器保留 `.system` 默认值以兼容无需控制时间的调用；测试可注入固定或手动推进的闭包。SQLite store 在 `open` 时接收并将同一值传给 writer、只读 reader、存储观测及在线备份；连接仅携带该依赖供事务 helper 使用。已有显式 `now:` 的操作继续以调用者时间为准。秒、微秒文件名和 UTC 日窗口保留各自取整方式；耗时和截止时间仍使用单调时钟。
