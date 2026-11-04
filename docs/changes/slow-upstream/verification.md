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

## 独立评审修正验收（本次）

2026-11-04，macOS arm64、Apple Swift 6.4.2。本节仅记录本次评审修正，与上方此前分支工作的失败和补跑记录分开。五项发现均确认，无异议；未访问 SSH、部署、真实订阅或 OpenAI 端点，未执行 Linux/Docker、前端或真实客户端检查。

### 改动与定向检查

- 显式非完成状态不得合成完成事件；in_progress/queued/incomplete 保持 partial/unknown，failed/cancelled 记失败，可信完整/部分计数独立保留。
- 多张完成图片按到达顺序聚合；图片索引区别图片与重复投递，无索引时相同完整事件视为重复。用量以请求级累计快照逐字段取可信最大值，不相加重复聚合计数；后到计数及畸形输出前的可信计数均保留。
- SSE 无数字状态的永久拒绝与 JSON 400 映射一致；显式 422 保留。修正图片及 turn diagnostics 的旧 502 预期。
- 原生 WS 最终编码超过 12 MiB 沿既有 conversation_too_large 路径拒绝，等于边界仍允许；不增加重试。原 16 MiB 常量仅用于被替换的拒绝判断，没有独立用途，已删除；其他大小限制与诊断桶不变。

| 实际命令/检查 | 本次结果 |
| --- | --- |
| `swift build --product codexone -j 12` | 四次构建均通过；最后一次包含最终 Swift 代码。 |
| `python3 scripts/verify_images.py --binary .build/debug/codexone` | 两次定向运行均通过 HTTP/WS 配置；最终版本覆盖完整/部分计数与五种状态、n=2 有序多图、相同图片不同索引、重复聚合计数、后到用量、第二张畸形/重复索引仍保留用量、JSON/SSE 同一拒绝及显式状态。另在下方续跑通过。 |
| `python3 scripts/verify_upstream_ws_body_limit.py --binary .build/debug/codexone` | 定向两合约通过，首次全量中也通过；12/16 MiB 边界前/等于/后、拒绝前无派发/attempt、连接复用及既有 1009/断流/取消行为。 |
| `python3 scripts/verify_turn_diagnostics.py --binary .build/debug/codexone` | 全量命令发现旧预期失败；仅将该 fixture 的 502 改为 400 后，定向 30 场景通过。 |
| `python3 scripts/check_docs.py` | 多次检查均通过，最终文档更新后另运行。 |
| `git diff --check`、`git diff --cached --check` | 通过；检查本次差异与新增内容仅含合成资料。 |

### 唯一一次完整命令及续跑

`CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 只执行一次：文档、架构、Swift 格式、构建、全部 Swift 测试及分片清单检查通过。Swift 测试为 Core 67、End-to-End 88、Runtime 7、Adapters 299，共 461 个。内含命令为 `python3 scripts/check_docs.py`、`python3 scripts/check_architecture.py`、`swift format lint --strict --recursive Sources Tests Package.swift`、`swift build --build-tests -j 12`、`swift test --skip-build --no-parallel -j 12` 与 `python3 scripts/backend_shards.py --check`。

该完整命令在 24 个脚本通过后，于 verify_turn_diagnostics.py 失败：其 stream fixture 仍期待 502，修复后的实际状态是 400。修正 fixture 后定向通过，然后从 verify.sh 提取原参数顺序，仅续跑后面 19 个尚未执行脚本，全部通过。最终 44/44 脚本各有通过结果；**完整命令本身失败，未在 fixture 修正后重跑**。Swift 代码在完整验证后未改动，不把分段通过表述为完整命令全绿。本次没有其他编译或测试失败。

| 脚本（均以 `python3` 和 verify.sh 原参数执行） | 本次实际结果 |
| --- | --- |
| `scripts/verify_storage_pressure.py` | 首次全量通过（3s） |
| `scripts/verify_key_maintenance.py` | 首次全量通过（2s） |
| `scripts/verify_snapshot_restore.py` | 首次全量通过（6s） |
| `scripts/verify_process.py` | 首次全量通过（2s） |
| `scripts/verify_execution.py` | 首次全量通过（1s） |
| `scripts/verify_accounts.py` | 首次全量通过（0s） |
| `scripts/verify_protocol.py` | 首次全量通过（8s） |
| `scripts/verify_gateway_diagnostics.py` | 首次全量通过（1s） |
| `scripts/verify_client_protocol.py` | 首次全量通过（26s） |
| `scripts/verify_websocket.py` | 首次全量通过（6s） |
| `scripts/verify_upstream_ws_body_limit.py` | 首次全量通过（150s） |
| `scripts/verify_upload_deadline.py` | 首次全量通过（119s） |
| `scripts/verify_slow_ingress.py` | 首次全量通过（37s） |
| `scripts/verify_response_finish.py` | 首次全量通过（83s） |
| `scripts/verify_protocol_rejections.py` | 首次全量通过（1s） |
| `scripts/verify_upstream_zstd.py` | 首次全量通过（91s） |
| `scripts/verify_ws_address_candidates.py` | 首次全量通过（13s） |
| `scripts/verify_upstream_proxy.py` | 首次全量通过（90s） |
| `scripts/verify_upstream_events.py` | 首次全量通过（22s） |
| `scripts/verify_codex_shapes.py` | 首次全量通过（9s） |
| `scripts/verify_text_contract.py` | 首次全量通过（106s） |
| `scripts/verify_json_order.py` | 首次全量通过（9s） |
| `scripts/verify_upstream_json.py` | 首次全量通过（7s） |
| `scripts/verify_request_parameters.py` | 首次全量通过（5s） |
| `scripts/verify_turn_diagnostics.py` | 首次失败：旧预期 502；修正为 400 后定向重跑 30 场景通过 |
| `scripts/verify_optional_reasoning.py` | 续跑通过（2.5s） |
| `scripts/verify_context.py` | 续跑通过（3.7s） |
| `scripts/verify_compaction_stream.py` | 续跑通过（5.1s） |
| `scripts/verify_images.py` | 续跑通过（78.9s） |
| `scripts/verify_migration_readiness.py` | 续跑通过（9.0s） |
| `scripts/verify_control.py` | 续跑通过（61.5s） |
| `scripts/verify_home_panel.py` | 续跑通过（1.6s） |
| `scripts/verify_business_day.py` | 续跑通过（2.9s） |
| `scripts/verify_keys.py` | 续跑通过（15.9s） |
| `scripts/verify_model_profiles_import.py` | 续跑通过（0.2s） |
| `scripts/verify_key_export.py` | 续跑通过（0.1s） |
| `scripts/verify_key_import.py` | 续跑通过（5.5s） |
| `scripts/verify_trial_provider.py` | 续跑通过（3.9s） |
| `scripts/verify_lite.py` | 续跑通过（2.4s） |
| `scripts/verify_admin.py` | 续跑通过（9.8s） |
| `scripts/verify_admin_round2.py` | 续跑通过（0.8s） |
| `scripts/verify_admin_assets.py` | 续跑通过（1.6s） |
| `scripts/verify_pool_config.py` | 续跑通过（2.5s） |
| `scripts/verify_migration_cutback.py` | 续跑通过（2.2s） |

### 未验证与回退

真实提供者多图事件/用量格式、真实 Codex 客户端自动回落及其更高层重试、Linux/Docker 和部署环境仍未验证。本地假上游成功不能证明真实兼容。没有 schema/凭证迁移；回退会恢复这些缺陷。未推送或开 PR。
