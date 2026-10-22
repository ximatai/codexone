# 验证与复盘

## 2026-10-22 · 托管 dispatch 准入屏障

主 Agent 亲自实现/复盘，macOS arm64 / Swift 6.4。`./scripts/verify.sh --backend` 完整通过：84 个 Swift 测试函数与全部进程/HTTP/SSE/WS/Key/session/账号脚本。本切片未改前端，不新增浏览器通过声明。

新增四项真实 Crypto/SQLite 测试：准备凭证后禁用/开始刷新/重新授权会使旧快照拒绝且不存在 attempt；实际等待原访问期限过期后也拒绝。enabled/ready 与 draining 可信续接分别验证，disabled/过期 access 不会准备可派发 work；缺账号快照的匹配旧路径拒绝，安全快照持久往返无 token。Key 撤销与账号快照在同一准入事务复核，拒绝不留 attempt；正确准入后普通禁用仍允许绑定与如实结算，不能擦除已有责任。

v3 构造保留执行 intent 与 refreshing 账号，普通启动明确拒绝；显式迁移生成私有 pre-v4 备份，真实打开备份验证源版本 3/intent/refreshing 均未提前恢复。v4 普通启动再变 unknown/auth_uncertain，历史 admission.accountSnapshot 为 nil，重复迁移没有第二个完成备份。旧 v1/v2 的 Key 保留/一致性备份和迁移中断事务回滚继续通过；进程脚本更新为 v4 并完整重跑，包括三组账号 SIGKILL。备份文件计数仅纳入完成的 .sqlite，不能把打开备份时产生的 WAL 辅助文件当额外备份。

此切片只建立持久屏障，尚未把账号选择接入 HTTP/WS，continuation 由后续应用归属/连接核实，不由客户端提供。未测试真实订阅/额度/生产 TLS，不代表账号池可路由或 M3 整体完成。提交后 review 与 Linux 结果待对应提交完成后记录。


f488da5 独立 review 无需修复或阻塞，reviewer 独立运行新增四项真实 SQLite 测试全部通过。该精确快照 Linux amd64 / Swift 6.4 本地单并发容器完整后端 84 测试与全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。仅持久屏障验收，不推导选择器/传输或真实订阅。


主 Agent 后续自我复盘发现 namespace 边界不一致：可信凭证上下文允许 512 字节，旧准入/指定 namespace 的归属查询却混用 256 字节标识校验。亲自统一 namespace 上限至 512，其他标识保持 256（管理账号/Key 仍各自 64）。新增真实 Crypto/SQLite 最长 namespace 的准入、绑定、指定 namespace 读取与跨主体拒绝，以及 257 字节 attempt 继续拒绝。macOS 完整后端 85 测试与全部脚本通过；689fdc9 独立 review 无阻塞，reviewer 定向回归通过；同快照 Linux amd64 / Swift 6.4 单并发完整后端 85 测试及全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。


## 2026-10-22 · 有效 access 的原子选择用例

主 Agent 亲自实现并复盘；七项新增真实 Crypto/SQLite 与 Runtime 测试通过。两个并发准入观察当前 intent 后选择不同账号；结算后固定 seed 的分流在重新打开 DB 后一致。归属测试覆盖跨账号同名对象、多个引用交集、连接消歧、跨主体与不一致连接拒绝；准备后新增同名绑定在准入事务拒绝，禁用全部候选和撤销 Key 均不留新 attempt。draining 的伪造无归属 continuation 拒绝，已有引用可续接；全局容量不足不换账号循环。

实际 Core 池用例使用受监督 finalizer：一个执行保持在途时另一个选择其他账号；第二执行观察部分用量后失败，仅调用一次并最终 unknown，已观察用量保留；已有 response 续接回原账号。所有收尾容量占满时，准备闭包调用数为零；过期 access 返回需要刷新且未执行生成，ticket 无泄漏。复盘提取共用 SQL 准入事务与 Core 收尾所有权，避免两个入口出现不同治理或 orphan intent。

本切片没有把 HTTP/WS 数据面连接池用例；过期/正在刷新候选与共享刷新 owner 的衔接、健康/额度仍待后续实现。无真实订阅或额度调用，也没有新增前端/浏览器验收声明。macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend` 通过，92 个 Swift 测试函数及全部脚本；6074b3d 独立 review 无阻塞，reviewer 七项定向回归通过；同快照 Linux amd64 / Swift 6.4 本地单并发完整后端 92 测试及全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。


## 2026-10-22 · 共享刷新的路由衔接

主 Agent 亲自实现和复盘，新增四项真实 SQLite/Runtime 回归通过。管理刷新已经持久 begin intent 后，路由携当前更高 revision/同 credential version 仍加入同一工作；错误版本及用更新 revision 伪装管理重试拒绝。取消一个路由等待者不会取消共享 provider；独立持久 refreshing 而无 Service owner 的状态拒绝且不会再请求 provider。

实际池用例中两个过期账号只刷新一个；两个请求共享一次刷新，取消一个立即归还无 intent 的执行 ticket，另一个在新凭证提交后唯一派发，另账号版本不变。明确重新授权失败及未知失败分别保留 requires_auth/auth_uncertain，不向第二账号刷新，也没有生成调用。刷新期间账号禁用或 Key 撤销后，已接受刷新照实提交新版本，但执行重新检查后拒绝，操作闭包调用为零。旧管理单飞和取消测试继续通过。provider 为无凭证合成端口实现，此处不声称真实网络/TLS/订阅验收。

macOS arm64 / Swift 6.4 完整后端 96 测试及全部脚本通过；提交后 review 与同快照 Linux 待补记。HTTP/WS 接入、健康/额度仍未完成。
