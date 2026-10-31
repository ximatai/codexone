# 验证：下游断开时补发中断并续读终态

日期：2026-10-31。环境：macOS arm64；仅本机合成 socket、账号和用量数据。

## 实现与覆盖入口

- 补发复用原连接 owner、turn 状态和续读任务；dispatch 标记保存在原 turn 中，下一轮重置。只发送 `type`、`response_id` 和非默认 lane 的 `stream_id`，不携带客户端额外字段，不新增准入。
- `verify_client_protocol.py`：无客户端中断时断开，补发一次、终态按输入5/输出3/估算8结算，outcome 保留 `cancelled`/`client_cancelled`；8条续读保留全部连接槽，结束后全部8槽可重新取得。
- 同一入口覆盖 EOF、error、10秒无终态、未知事件后无终态：unknown、不重放、释放本地资源后新请求成功。unknown 的治理暴露继续按 U03/U06 保留，不视为退款。
- 客户端已中断不重复补发；同 lane 排队请求在断开后不 dispatch；未发 create 与已终态断开不补发。请求已 dispatch 但没有响应身份时，在同一期限内等到生命周期 ID 后定向补发；始终缺身份时有界取消。
- 多 lane 中一条补发失败不提前终止另一条续读；非默认 lane 的中断定位字段逐项检查。运行时停止在5秒内取消已进入续读的任务；原执行期限2秒时不延长至10秒。
- Swift turn 测试检查未 dispatch、缺身份、已中断、已终态及复用下一轮的资格；账号池 socket 测试覆盖握手中/在途断开、运行时取消与原期限。
- 原有 `verify_protocol.py` 和 `verify_images.py` 保留 HTTP/SSE 与原生 Images 断开回归；HTTP→WS 桥接仍不进入原生下游续读路径。
- 没有新增日志；合成入口断言未知头只记录名称、已知头不告警，正文、头值与凭证不进入日志。

## 实际验证

| 命令 | 退出码 | 耗时 | 结果 |
|---|---|---|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 521.35秒 | Swift 261项与全部后端合成脚本通过；严格格式、架构、构建与后端入口内的文档检查通过 |
| 定向 Swift（命令如下） | 0 | 26.50秒 | 5项定向测试通过（其中1项含3个参数用例） |
| `python3 scripts/verify_client_protocol.py --binary .build/debug/codexone` | 0 | 26.91秒 | 补发/取消结算、失败/不重放、容量回收、lane隔离、停止与短期限全部通过 |

定向 Swift 命令：

```sh
swift test --disable-sandbox --no-parallel -j 12 --filter 'Interrupt|interruption|disconnectSettlement|poolNativeWebSocketDisconnectAndRuntimeCancellation'
```

Swift 四个测试 target 分别为40、44、3、174项。独立 `python3 scripts/check_docs.py`：退出0，0.05秒；206份 Markdown、本地链接与变更结构检查通过。

首次定向协议入口退出1，30.73秒：合成上游等待某条 lane 的终态放行时阻塞了唯一请求 reader，无法读取另一条 lane 的中断；测试设施改为带结束/等待路径的延迟终态 worker 和串行 writer，重跑该失败入口通过。首次依赖下载较慢的预备构建由执行者中止（130）；从已有 SwiftPM 缓存复制锁文件指定 commit 到本 worktree 的忽略构建目录后，`swift build --disable-sandbox -j 12 --skip-update` 通过，锁文件未改。

## 兼容边界与承接

不做上游能力探测，复用既有原生 WS `response.interrupt` 能力假设；提供者拒绝、断开或不返回可信终态时保守保留 unknown，不重试生成。未增加新的配置或客户端握手要求。

旧客户端无需修改消息格式，已关闭连接不会收到额外内容；可见差异在于停止后的用量可能从 unknown 变为按实际结算，outcome 仍为客户端取消；本地连接槽最多保留10秒，高并发下新连接可能暂时遇到容量限制。真实上游是否支持、是否及时给出可信终态尚需主 Agent 按授权验收。

未运行 Docker/Linux、真实订阅、OpenAI、部署、推送或 PR；Linux 与真实 Desktop 停止验收由主 Agent 承接。STATUS 按任务授权由主 Agent 维护。
