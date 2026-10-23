# 只读实现/测试审计 · 2026-10-23

平台：macOS arm64，Swift 6.4；审计基线 `08a36c0`，产品源码与 `ff1322f`相同。主 Agent 亲自核对和执行；没有修改 Sources、既有 Tests、业务 scripts、客户端或线上服务。仅新增分析文档及独立诊断探针。全部是本地 loopback、固定合成模型/Key/消息、临时私有数据目录，无真实账号/登录文件、外部生成或额度消耗。

## 实际执行

`swift build --skip-update -j 4` exit0，增量构建通过；工具提示 skip-update 已废弃，不影响本次结果。探针只使用当前构建的 debug 程序，不是发行二进制验证。

```sh
python3 docs/changes/gateway-reliability-audit/probe.py --binary .build/debug/codexone
```

探针最初在仓库外执行同一场景主体，随后移入此处并改为显式 binary 参数/可移植脚本定位，移除私有输出路径，增加单场景选择及未提交SSE时的JSON错误码采集；不改变场景或网关。stdout 仅固定场景名、事件类型、状态、错误码及账本摘要；不打印请求正文或认证材料。输出是27项**行为观察**，不是27项“兼容验收通过”。正常对照与每种改变各一次，三传输均只有一次上游调用。

| 合成场景 | HTTP→HTTP SSE | HTTP→WS SSE | 原生 WS | 账本/结论 |
|---|---|---|---|---|
| 正常 created/added/done/completed | completed | completed | completed | 全部 settled，failure空 |
| created 为 response A、终态为 B | 接受 completed | invalid_upstream_turn | invalid_upstream_turn | HTTP settled；两条WS unknown，说明关联校验差异 |
| done 的 message A、终态相同位置为 B | 接受 completed | 接受 completed | 接受 completed | 全部 settled；未核对两种完成视图一致 |
| completed 事件内部 status=failed | 接受 completed | 接受 completed | 接受 completed | 全部 settled/failure空；状态矛盾未分类 |
| failed + 合成 error + 完整 usage | upstream_execution_failed | upstream_execution_failed | upstream_execution_failed | 全部 settled/upstream_rejected；用量未丢，错误正文未回显 |
| failed 无 error + 完整 usage | response.failed | response.failed | response.failed | 全部 settled/upstream_rejected；不能说 failed 全部不支持 |
| completed 的 usage=null | completed | completed | completed | 全部 unknown，无计量证据，未冒充零结算；输出成功与未知计量独立 |
| usage输入2/输出1/缓存0/total=-1 | 接受 completed | 接受 completed | 接受 completed | 全部按已校验字段 complete/settled，未过滤矛盾的下游字段 |
| 首事件为合成 error/status429 | unsupported_upstream_event/502 | invalid_upstream_turn/502 | invalid_upstream_turn错误帧 | 全部 unknown；按不支持/无效协议归类，未保留限流分类 |

首 error 场景的HTTP上游也发送SSE；下游尚未输出任何事件，故返回JSON 502。移入后的单场景补采集进一步确认 unsupported_upstream_event；不要把下游错误JSON误认为上游返回了非SSE。WS正常对照已验证相同探针链路可执行，ID切换对照在WS确实被拒绝。`settled`表示用量结清，不等于业务成功。异常状态/关联场景没有在真实客户端重现，更未证明真实提供者会发送相同数据；本轮不宣称工具重复执行、数据泄露或真实账单损失。

补采集命令：`python3 docs/changes/gateway-reliability-audit/probe.py --binary .build/debug/codexone --case error-first --transport http`，exit0，一次上游调用；此次明确采集下游JSON错误码，未重复其余已完成观察。

## 六项已有测试

```sh
swift test --skip-build --filter 'poolNativeWebSocketRechecksAccountAndKeyBetweenTurnsWithoutReconnecting|poolHTTPExplicitProviderStatusesPersistHealthAndStopNewDispatchWithoutReplaying|poolUsageCollectsNativeWarmupAndFailedTerminalAcrossNativeAndBridgedWebSockets|poolHTTPPartialUsageRemainsUnknownWithoutDroppingObservedCosts|observedUsageSurvivesLaterTransportOrCancellationErrors|accountModelCooldownIsDurableIdempotentAndIndependentOfLocalFailures'
```

exit0，实际选中六项并全部通过（测试进程分组1+4+1）。证明限定场景的逐轮Key/账号复核、HTTP状态健康分类、WS失败终态/预热用量、部分证据及取消后已知用量保留。skip-build复用既有相同源码/测试的测试程序，不冒充本轮完整重新编译测试全集；本轮产品/Tests相对既有候选没有变化。

## 静态核查与覆盖限制

已核对：`ResponseRequest`/`ClientTools`/`ModelCatalog`/`ModelProfileSnapshot`，`HTTPResponseExecution`/`WebSocketResponseExecution`/`ProviderObservation`/`ExecutionObservation`，`ResponsesDataService`/`WebSocketTurns`/`WebSocketPeer`，`AccountPoolGateway`/`ExecutionCoordinator`/`ExecutionFinalizer`/`SQLiteAccountHealth`，及相关协议/上下文/压缩/Key/长任务/容量/夹具/客户端脚本、CI与候选构建入口。不是穷举全仓安全审计。

未新增运行：完整后端/前端、Linux、Desktop UI、实际内置CLI、生产订阅、慢lane填满/慢上传/保活组合、两账号共享5xx耗尽、排队后Key轮换及真实客户端下一轮对不一致历史的处理。前次Lite与缺total的实际CLI证据仍见[先前调查](../parallel-key-trial/verification.md#用户要求先定位不修复后的只读调查)，本轮没有重复它。文档/探针入口检查与集中review结果见任务及STATUS；不因本轮分析而解除原未验收项。

文档结构检查130份通过；探针AST语法检查、差异空白及新增材料隐私自查通过。它们不验证远端URL、协议或运行正确性。

提交 `0103907` 后集中review无需要修正的P1/P2或事实错误。Reviewer独立执行 `probe.py --binary .build/debug/codexone --case status-mismatch --transport http`，一次loopback合成上游，确认completed/status=failed仍settled/complete且failure为空；未重复其余矩阵或产品全集，没有修改业务文件。
