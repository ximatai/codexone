# 慢上游修复验证

记录 2026-11-04 的 macOS arm64、本地真实 HTTP/WebSocket 与合成提供者验收，不代表真实订阅或部署兼容。

## 环境与范围

Apple Swift 6.4.2，目标 arm64 macOS。全部构建使用 `-j 12`；只运行当前工作树代码与 loopback fake upstream，没有 SSH、真实订阅、OpenAI 网络请求、推送、PR、Linux 或 Docker 构建。无 UI 变更，未运行前端/浏览器检查。

## 定向检查

| 实际命令/检查 | 结果与范围 |
| --- | --- |
| `swift build --product codexone -j 12` | A、B（含空媒体类型修正）、C、D、E 与 A 上传进度补充分别构建通过。E 首次编译因捕获 noncopyable Mutex 失败，改用单一引用 owner 后重建通过。 |
| `python3 scripts/verify_upload_deadline.py --binary .build/debug/codexone --transport images` | 初版五场景通过；A 进度空闲补充后的最终版本七场景全通过：慢传、上传后静默、慢传后静默、进度停滞、取消、上传中断、持续推进但超过总期限。最初测试混用静态/托管 Key 导致启动失败、随后测试节奏误用 WS 值导致总期限失败；修正测试后重跑通过。 |
| `python3 scripts/verify_images.py --binary .build/debug/codexone` | B、D 分别完整通过 HTTP/WS 两种配置；最终版本也纳入下方脚本轮次。合成 JSON 字段/状态/用量、完整 JSON→SSE、SSE→JSON、提供者错误、残片/截断/重复终态、缺失时间戳、许可/预算竞争与取消。 |
| `python3 scripts/verify_upstream_ws_body_limit.py --binary .build/debug/codexone` | C 定向两合约全部通过；另纳入最终脚本轮次。12/16 MiB 边界前/等于/后，HTTP JSON/SSE/native、续接、1009 与生命周期竞争、其他 close/EOF、取消、单 attempt 及账本。 |
| `python3 scripts/verify_upload_deadline.py --binary .build/debug/codexone --transport websocket` | 慢传、两类静默、停滞、取消五场景通过。另直接调用同脚本 `run(..., 'websocket', 'disconnect')`，帧未完成即断开保持 502 unknown、单派发、无 HTTP 重试。 |
| 修改前的本地 HTTP 慢入站复现 | 持续慢传超过固定 10 秒，客户端得到 ConnectionResetError，无 JSON。 |
| `python3 scripts/verify_slow_ingress.py --binary .build/debug/codexone` | 通过：并发 Content-Length/chunked 的 12 MiB 正文超过 10 秒、空闲期限与正文末尾竞争、408 JSON、断开/预算释放、20 MiB 后续请求、无头上游断开 JSON 502 与固定 cause、单派发和账本。 |
| `swift test -j 12 --no-parallel --filter ExecutionBudgetTests` | 最终四测试通过，含上传 idle→first 原子切换、重复 EOF、早到事件不被覆盖。该补充发生在完整 Swift 轮次后，只定向重跑，没有重复整套 macOS 测试。 |
| 三个图片 End-to-End 测试的 `swift test -j 12 --no-parallel --filter ...` | 初次定向编译因 fixture 的可选 Data 未解包失败，修正后 3/3 通过；A 进度补充后再用同过滤器 `--skip-build` 3/3 通过。过滤器是下列三个完整函数名以竖线连接。 |
| `python3 -m py_compile scripts/verify_upload_deadline.py` | 通过。其他修改脚本由实际进程矩阵加载运行。 |
| `python3 scripts/check_docs.py`、`python3 scripts/check_architecture.py`、`python3 scripts/backend_shards.py --check` | 通过；最终文档整理后另检查文档/架构。 |
| `swift format lint --strict --recursive Sources Tests Package.swift`、定向 Swift lint、`git diff --check` | 最终通过。 |

图片过滤器函数名：`poolImagesUseOneIntentAndOwnedAccountAcrossHTTPBridgeAndNativeTurns`、`poolNullModelScopesAuthorizeImagesAndToolsOnlyWithinConfiguredCatalog`、`sessionMetadataNativeWebSocketAndImagesFeedControlAffinity`。

## 完整验证轮次与失败记录

`CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 首次在格式检查发现 B 空媒体类型修正后的一行超长，未开始构建或测试。格式化后，以 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-build` 继续：构建通过，完整 Swift 测试实际运行 459 个；Core 67、Runtime 7、Adapters 297 通过，End-to-End 88 中 85 通过、3 失败（15 条断言）。失败为旧图片 fake 用 Responses SSE、且旧 wire 断言仍要求 generations 不增加 stream；更新为原生图片完成事件、保留 created/data 并检查 upstream stream/Accept 后，上述 3 测试定向通过。未重复完整 Swift 轮次，因此完整命令本身不是全绿记录。

随后执行一次 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-scripts all`，已通过 29 项后，迁移就绪脚本的旧图片 fake 返回 Responses SSE 而失败。修正该 fixture 的原生完成事件及 created 后，从 verify.sh 逐条提取原参数，仅续跑失败项和 14 个尚未运行项，全部通过；没有重复 29 个已通过项。总计 44/44 脚本最终通过，每项见下表。A 上传进度补充期间该轮的上传脚本进程已加载旧六场景列表；其现有场景通过，补充后的最终七场景另定向通过。新增进度代码通过独立构建、四个阶段测试、七个真实图片上传场景及三个账号池图片协议测试；不声称它在所有 Swift 测试上重新跑过。

## 最终脚本清单

| 脚本（均以 `python3 scripts/...` 执行） | 实际结果 |
| --- | --- |
| `verify_storage_pressure.py` | 通过 |
| `verify_key_maintenance.py` | 通过 |
| `verify_snapshot_restore.py` | 通过 |
| `verify_process.py` | 通过 |
| `verify_execution.py` | 通过 |
| `verify_accounts.py` | 通过 |
| `verify_protocol.py` | 通过 |
| `verify_gateway_diagnostics.py` | 通过 |
| `verify_client_protocol.py` | 通过 |
| `verify_websocket.py` | 通过 |
| `verify_upstream_ws_body_limit.py` | 通过 |
| `verify_upload_deadline.py` | 通过 |
| `verify_slow_ingress.py` | 通过 |
| `verify_response_finish.py` | 通过 |
| `verify_protocol_rejections.py` | 通过 |
| `verify_upstream_zstd.py` | 通过 |
| `verify_ws_address_candidates.py` | 通过 |
| `verify_upstream_proxy.py` | 通过 |
| `verify_upstream_events.py` | 通过 |
| `verify_codex_shapes.py` | 通过 |
| `verify_text_contract.py` | 通过 |
| `verify_json_order.py` | 通过 |
| `verify_upstream_json.py` | 通过 |
| `verify_request_parameters.py` | 通过 |
| `verify_turn_diagnostics.py` | 通过 |
| `verify_optional_reasoning.py` | 通过 |
| `verify_context.py` | 通过 |
| `verify_compaction_stream.py` | 通过 |
| `verify_images.py` | 通过 |
| `verify_migration_readiness.py` | 通过（旧 fixture 修正后重跑） |
| `verify_control.py` | 通过 |
| `verify_home_panel.py` | 通过 |
| `verify_business_day.py` | 通过 |
| `verify_keys.py` | 通过 |
| `verify_model_profiles_import.py` | 通过 |
| `verify_key_export.py` | 通过 |
| `verify_key_import.py` | 通过 |
| `verify_trial_provider.py` | 通过 |
| `verify_lite.py` | 通过 |
| `verify_admin.py` | 通过 |
| `verify_admin_round2.py` | 通过 |
| `verify_admin_assets.py` | 通过 |
| `verify_pool_config.py` | 通过 |
| `verify_migration_cutback.py` | 通过 |

## 第 6 项的复现与边界

原固定入站期限直接关闭连接已由慢传复现并修复。另在完整 Swift 测试 `poolHTTPDownstreamCancellationReleasesExecutionAndLeavesUnknown` 中复现相同日志顺序：Account selected、cause=cancelled 的 execution_indeterminate、cause=channel_closed 的 downstream_json_write；测试确认已经准入、只派发一次并留下 unknown。真实进程 `verify_response_finish.py` 的下一个请求未读完即 reset 场景，也得到 cause=io_errno_54 和 downstream_json_write，但该新请求没有 attempt。必须按 request_id 关联，不能把相邻的账号选择日志或缺少可信用量当作未准入证明。

因此不能唯一确定生产第 6 项的触发原因；新增原因 token 供后续核对。连接已被对端 reset/取消时，协议上无法再送 JSON；可写且正文超时的连接已验证返回 JSON 408。未知执行仍未知，不重试、不换账号、不补零用量。

## 尚未验证与偏差

- 未调用真实提供者，edits 实际 Content-Type、12 MiB 路由效果和真实 SSE/非流式图片 JSON 的所有字段等价仍未知；本任务只证明合成格式的 JSON 字段和值对等，不承诺另一种格式的原字节或未出现在流中的字段。
- 未发现网关代码中固定 30 秒上游 WS 上传期限；15 MiB 中断的真实原因未确定。写 future 失败与无事件都不能证明提供者未执行，所以按任务条件不新增中断后 HTTP 重试。
- 入站 120 秒总读取上限未完整等待墙钟验收；10 秒空闲与末尾竞争、执行总期限及上传进度空闲已通过真实协议验证。未运行实际 Nginx/TLS、Linux、Docker、真实客户端组合或前端检查。
- 完整 Swift 轮次有已修复并定向重跑的失败；没有重复完整 macOS 轮次。过程中 proposal/tasks/本验证草稿的文档框架检查曾报告缺失说明或相关文档段，补齐后检查通过。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [协议](../../reference/specs/protocol.md)
