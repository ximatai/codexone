# 验证：客户端协议前向兼容与原生 WebSocket 中断

日期：2026-10-31。平台：macOS arm64，Swift 6.4.2工具链。全部使用本地合成上游、临时Key与临时SQLite，不调用真实账号或远程服务。

## 定向证据

- `scripts/verify_client_protocol.py`：独立RFC6455客户端验证Cancel确认在终态前/后（断言实际下发顺序）、Drain、已结束/外来ID本地failed（不写上游）、并行lane、后续create可用；控制不新增attempt，原turn按终态usage结算。
- 同一socket验证未知类型绑定前400、绑定后原字节转发、含input/model/tools（含null）拒绝、突发超速400后继续create。上游收到条数与下游成功转发数一致。
- 未准入生命周期分别在空闲与在途时触发：连接关闭、不暴露未准入ID、不重放；附加unknown记录沿用首轮持久Key/账号归属，在途无终态仍unknown。注入unknown插入失败时仍关闭、记录`unknown_record_failed`，不伪称已持久化。
- `poolNativeWebSocketControlsAndUnexpectedGenerationKeepDurableOwner`：真实本地账号池socket覆盖绑定前拒绝、绑定后扩展、三种中断顺序、结束ID、本地固定身份与未知生成兜底；4条正常执行settled、1条附加unknown，全部归属同一alice Key及所选账号，只有1次上游握手。
- HTTP、Images与控制接口已有socket验证增加新`x-codex-future-header`与门控头断言；独立WS验证握手前缀头、认证/账号/门控隔离。Swift定向验证单值8 KiB、32条上限与Connection逐跳排除。
- 长连接归属回归：一个在途lane跨越其他lane的1024轮历史淘汰后，仍可中断；其终态后确认仍按最近结束集合路由。终态提交等待每lane仅一项（最多33项），reader等待期间受连接取消及既有下游写期限监督。
- 合成日志断言类型名/头名、结果、客户端类别可见，消息内容、Key、临时目录不进入日志；机器标识不合法时记invalid。终态后事件沿用提供者错误脱敏及usage筛选，不供给下一attempt的证据sink。

## 命令

| 命令 | 退出码 | 关键证据 |
|---|---|---|
| `swift build --disable-sandbox` | 0 | `Build complete! (1.44秒)` |
| `swift test --disable-sandbox 2>&1 \| tail -20`（pipefail） | 0 | 四组35/43/3/149项，共230项通过；包含三种未准入起点参数化用例 |
| `swift format lint --strict --recursive Sources Tests Package.swift` | 0 | 无诊断 |
| `python3 scripts/check_docs.py` | 0 | 176份Markdown、本地链接与变更产物通过 |
| `CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 230项Swift及全部后端脚本通过；包含新协议socket、Images/控制头透传、WS/代理/恢复/Key治理与迁移切回 |

一次并行构建期间的完整验证在子进程启动断言退出1；该轮与重新链接同一可执行文件重叠，随后停止并行构建并串行重跑，最终串行重跑完整通过（退出0），以上表记录为最终出口。

## 边界与承接

- Linux verification、部署后Desktop实际停止回复和中途追加消息由主Agent承接，未在此执行。
- 不修改STATUS、web或Package文件；未add/commit/push/PR。
- 无自动重连或重放；HTTP与桥接继续以断连取消。
- 未准入生成的模型未知，责任估算沿用连接首轮快照；存储不可写或总attempt容量耗尽时无法保证新增unknown持久化，只能关闭并以固定分类日志暴露失败。

## 改动文件

- `Sources/CodexOneAdapters/Images/NativeImageExecution.swift`
- `Sources/CodexOneAdapters/Persistence/SQLiteExecutionStore.swift`
- `Sources/CodexOneAdapters/Transport/PoolWebSocketSession.swift`
- `Sources/CodexOneAdapters/Transport/ResponsesDataService.swift`
- `Sources/CodexOneAdapters/Transport/WebSocketClientControl.swift`
- `Sources/CodexOneAdapters/Transport/WebSocketPeer.swift`
- `Sources/CodexOneAdapters/Transport/WebSocketTurns.swift`
- `Sources/CodexOneAdapters/Upstream/HTTPResponseExecution.swift`
- `Sources/CodexOneAdapters/Upstream/WebSocketResponseExecution.swift`
- `Sources/CodexOneAdapters/Upstream/WebSocketUpstream.swift`
- `Sources/CodexOneCore/Application/Execution/ExecutionCoordinator.swift`
- `Sources/CodexOneCore/Application/Execution/ExecutionStore.swift`
- `Tests/CodexOneAdaptersTests/ClientProtocolCompatibilityTests.swift`
- `Tests/CodexOneAdaptersTests/ProtocolWireTests.swift`
- `Tests/CodexOneEndToEndTests/AccountPoolHTTPTests.swift`
- `docs/changes/client-protocol-forward-compat/tasks.md`
- `docs/changes/client-protocol-forward-compat/verification.md`
- `docs/specs/protocol.md`
- `scripts/verify.sh`
- `scripts/verify_client_protocol.py`
- `scripts/verify_control.py`
- `scripts/verify_images.py`
- `scripts/verify_pool_ws_client.py`
- `scripts/verify_protocol.py`
- `scripts/verify_websocket.py`
