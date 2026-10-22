# 验证与复盘

## 2026-10-22 · HTTP→WS 池桥接

主 Agent 亲自实现、实际验证和自我复盘。macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend` 通过，112 个 Swift 测试与所有进程/HTTP/SSE/WS/context/压缩/Key/session/账号/私有配置脚本。新增 NIOWebSocket 仅为既有 E2E target 的直接测试依赖，四个生产 target 与依赖方向不变，无前端变更或新浏览器声明。

两项新增真实 NIO WS server/URLSession 下游回归：HTTP JSON/SSE 经池准入后，用选中账号的 Bearer/account 头握手并发送 create；同主体 previous_response_id 返回原账号，跨主体引用在上游发送前拒绝。独立 compact 走同一所选 work 的 HTTP 路径，三次操作实际结算。保持一个 turn 在途时，第二请求选另一账号；提供者在 create 后断开只计一次请求和一个 unknown，不另连或换账号重放。下游伪造 account/私有头均不透传。

新增配置回归证明缺省与显式 HTTP 相同，选择 websocket 改策略版本但不改价格版本；未知传输值及其他覆盖仍拒绝。池下游 native 升级保留拒绝；此切片不能证明连接/命名 lane 已固定池身份。

复盘中完整旧 WS 脚本检出已关闭 peer 被移到准入之后检查，会新增一个不必要的 unknown。主 Agent 恢复既有 native peer 的准入前 beginTurn 屏障，桥接新 peer 则在已持久上下文中准备；完整旧终态/尾随事件隔离及所有脚本复验通过，没有放宽账本断言。首版失败结果未计通过。桥接提交后独立 review 发现总期限未覆盖握手的 P2，已纳入下述业务闭环修复。桥接旧快照 Linux 构建等待未收敛而中止，不计通过，统一在闭环出口检查。


## 2026-10-22 · 池 WS 业务闭环

主 Agent 亲自实现首轮容量一交接、结构化连接 owner 及逐 turn 的固定账号/Core 当前权限检查；复用原有 lane 调度与协议观察。桥接总期限同时覆盖连接/TLS/升级/正文。配置 websocket 开启原生池 WS，http 仍拒绝升级。

定向命令 `swift test --no-parallel --filter 'poolNativeWebSocket|poolHTTPWebSocket'`：独立 Python RFC6455 客户端接真实服务/SQLite/NIO 合成上游，验证 warmup 后多轮/双 lane、首 ticket 归零而连接存活、draining 续接/disabled/Key 撤销、跨主体首轮拒绝不握手、跨账号引用拒绝、固定身份刷新不另连、断开/静默握手及正文超时/Runtime 强制取消收敛。强制父取消可能抢先结束 finalizer，实际冷重开验证 intent 恢复为 unknown；没有将内存 ticket 清空当结算完成。首轮失败仅一个 unknown，不换账号重放。

自我复盘修正合成服务的 HTTP upgrade 解码暂停（静默握手改持续读取的原始 socket）与测试子进程重复 wait 的问题，未放宽 socket 释放或账本断言。macOS arm64 / Swift 6.4 九项定向测试通过，严格格式通过；提交后集中 review、主 Agent 修复复验及完整跨平台出口待完成。无前端变更，未新增 UI/真实账号/生产 TLS/恢复支持声明。
