# 验证与复盘

## 2026-10-22 · HTTP→WS 池桥接

主 Agent 亲自实现、实际验证和自我复盘。macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend` 通过，112 个 Swift 测试与所有进程/HTTP/SSE/WS/context/压缩/Key/session/账号/私有配置脚本。新增 NIOWebSocket 仅为既有 E2E target 的直接测试依赖，四个生产 target 与依赖方向不变，无前端变更或新浏览器声明。

两项新增真实 NIO WS server/URLSession 下游回归：HTTP JSON/SSE 经池准入后，用选中账号的 Bearer/account 头握手并发送 create；同主体 previous_response_id 返回原账号，跨主体引用在上游发送前拒绝。独立 compact 走同一所选 work 的 HTTP 路径，三次操作实际结算。保持一个 turn 在途时，第二请求选另一账号；提供者在 create 后断开只计一次请求和一个 unknown，不另连或换账号重放。下游伪造 account/私有头均不透传。

新增配置回归证明缺省与显式 HTTP 相同，选择 websocket 改策略版本但不改价格版本；未知传输值及其他覆盖仍拒绝。池下游 native 升级保留拒绝；此切片不能证明连接/命名 lane 已固定池身份。

复盘中完整旧 WS 脚本检出已关闭 peer 被移到准入之后检查，会新增一个不必要的 unknown。主 Agent 恢复既有 native peer 的准入前 beginTurn 屏障，桥接新 peer 则在已持久上下文中准备；完整旧终态/尾随事件隔离及所有脚本复验通过，没有放宽账本断言。首版失败结果未计通过。提交后 review 和同快照 Linux 待补记。
