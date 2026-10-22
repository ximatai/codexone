# 验证与复盘

## 2026-10-22 · 托管 dispatch 准入屏障

主 Agent 亲自实现/复盘，macOS arm64 / Swift 6.4。`./scripts/verify.sh --backend` 完整通过：84 个 Swift 测试函数与全部进程/HTTP/SSE/WS/Key/session/账号脚本。本切片未改前端，不新增浏览器通过声明。

新增四项真实 Crypto/SQLite 测试：准备凭证后禁用/开始刷新/重新授权会使旧快照拒绝且不存在 attempt；实际等待原访问期限过期后也拒绝。enabled/ready 与 draining 可信续接分别验证，disabled/过期 access 不会准备可派发 work；缺账号快照的匹配旧路径拒绝，安全快照持久往返无 token。Key 撤销与账号快照在同一准入事务复核，拒绝不留 attempt；正确准入后普通禁用仍允许绑定与如实结算，不能擦除已有责任。

v3 构造保留执行 intent 与 refreshing 账号，普通启动明确拒绝；显式迁移生成私有 pre-v4 备份，真实打开备份验证源版本 3/intent/refreshing 均未提前恢复。v4 普通启动再变 unknown/auth_uncertain，历史 admission.accountSnapshot 为 nil，重复迁移没有第二个完成备份。旧 v1/v2 的 Key 保留/一致性备份和迁移中断事务回滚继续通过；进程脚本更新为 v4 并完整重跑，包括三组账号 SIGKILL。备份文件计数仅纳入完成的 .sqlite，不能把打开备份时产生的 WAL 辅助文件当额外备份。

此切片只建立持久屏障，尚未把账号选择接入 HTTP/WS，continuation 由后续应用归属/连接核实，不由客户端提供。未测试真实订阅/额度/生产 TLS，不代表账号池可路由或 M3 整体完成。提交后 review 与 Linux 结果待对应提交完成后记录。


f488da5 独立 review 无需修复或阻塞，reviewer 独立运行新增四项真实 SQLite 测试全部通过。该精确快照 Linux amd64 / Swift 6.4 本地单并发容器完整后端 84 测试与全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。仅持久屏障验收，不推导选择器/传输或真实订阅。


主 Agent 后续自我复盘发现 namespace 边界不一致：可信凭证上下文允许 512 字节，旧准入/指定 namespace 的归属查询却混用 256 字节标识校验。亲自统一 namespace 上限至 512，其他标识保持 256（管理账号/Key 仍各自 64）。新增真实 Crypto/SQLite 最长 namespace 的准入、绑定、指定 namespace 读取与跨主体拒绝，以及 257 字节 attempt 继续拒绝。macOS 完整后端 85 测试与全部脚本通过；修复待提交后 review。
