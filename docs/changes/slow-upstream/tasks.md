# 慢上游修复任务

记录独立提交与本地合成验收，真实上游不在本任务范围。

- [x] A：图片上传 EOF 后启动首响应期限；真实慢传、停滞与取消验收。
- [x] B：有界媒体类型诊断及 streaming edits 完整 JSON 兼容。
- [x] C：降低独立 Responses HTTP 路由阈值；说明为何不重试中断上传。
- [x] D：非流式 generations 上游流聚合及输出/用量/错误/截断验收。
- [x] E：真实 HTTP 慢入站复现、未映射原因诊断及可写 JSON 错误。
- [x] 最后一次完整 macOS backend 验证与差异隐私检查。

2026-11-04 macOS：`swift build --product codexone -j 12` 通过；`python3 scripts/verify_upload_deadline.py --binary .build/debug/codexone --transport images` 五场景通过。测试脚本首次配置混用静态/托管 Key 导致启动失败，第二次慢读节奏误用 WS 值触及总期限；修正测试配置/节奏后完整重跑五场景通过。

## 相关文档

[提案](proposal.md) · [验证](verification.md) · [协议](../../reference/specs/protocol.md)

2026-11-04 B：`swift build --product codexone -j 12` 通过；`python3 scripts/verify_images.py --binary .build/debug/codexone` 两种配置（HTTP/WS）全部通过，含真实 HTTP 的 JSON→SSE 单图/多图、无效/混合结果与媒体类型拒绝，既有错误、许可竞争、断开、用量和预算验收。随后修正空媒体类型解析的索引风险并重新构建；该修正的运行测试随最终完整验证执行。

2026-11-04 C：`swift build --product codexone -j 12` 通过；真实 WS 上传五场景与新增帧中断场景通过，单派发/unknown/无健康惩罚。大小边界矩阵覆盖 12/16 MiB 的边界前/等于/后及 HTTP/SSE/native；Responses 合约通过，订阅合约仍在运行，最终结果在下方记录。普通写失败无法提供未执行证明，因此按任务条件不新增 HTTP 重试。

2026-11-04 C 补充：完整 `verify_upstream_ws_body_limit.py` 两合约通过。D：`swift build --product codexone -j 12` 与 `verify_images.py` 两配置通过。验收包含两客户端前缀、非流式 JSON 字段/状态/用量对等、原生 SSE 原字节、JSON 转完成事件、HTTP 错误、流内错误、终态前截断、终态后残片、重复终态、缺失时间戳、空图片、部分用量、取消、许可/预算竞争。D 的 JSON 对等为合成原生格式的字段和值，不能证明真实上游所有未知字段可由 SSE 恢复；缺失字段不伪造，真实格式仍未验证。

2026-11-04 E：修改前真实 HTTP 持续慢传超过固定 10 秒复现 `ConnectionResetError`、无 JSON；修改后 `verify_slow_ingress.py` 通过：并发 Content-Length/chunked 的 12 MiB 正文持续超过 10 秒成功，正文末尾/10 秒空闲期限并发竞争只返回 200 或完整 408 JSON，未准入超时/断开无 attempt，预算释放后 20 MiB 成功，上游无头断开返回 JSON 502、cause=remoteConnectionClosed、单 attempt unknown。初次编译因 Mutex 为 noncopyable、不能同时存储及捕获失败；改为单一引用存储后 `swift build --product codexone -j 12` 通过，再运行真实协议验收通过。

生产第 6 项仍不能唯一归因：`Account selected` 在 ExecutionCoordinator 的持久 admit 之后、上游 operation 内记录；“未见用量行/上传日志”不等于未准入（unknown 可能没有可信用量，小于诊断门槛或限流也可能没有上传日志）。本地证实固定入站期限会直接关闭连接，并修复；随后在下述取消测试复现相同日志顺序，仍不把入站期限修复宣称为全部生产事件的根因。原始未映射错误如今有固定 cause token 可继续定位，不变更未知状态映射或重试。120 秒总入站期限的完整墙钟等待尚未单独验收。

最终验证过程：完整入口首次停于 B 空媒体类型修正后的超长行，未进入构建/测试；格式化后以 `--backend-build` 继续。完整 Swift 测试实际跑 459 个：371 个 Core/Runtime/Adapters 与 85 个 End-to-End 通过，3 个 End-to-End 图片测试失败（共 15 条断言，旧 fake 返回 Responses SSE 而非图片完成事件，且仍要求 generations 原正文不加 stream）。修正 fake 的原生事件/created 与 wire 断言后，仅这 3 个真实 HTTP 测试定向重跑通过；中间定向编译因测试的可选 Data 未解包失败，修正后构建及 3 测试通过。没有重复整套 macOS 测试，不能将最初完整测试命令写成全绿。

E 补充证据：完整测试中的 `poolHTTPDownstreamCancellationReleasesExecutionAndLeavesUnknown` 使用真实本地 HTTP 与 fake provider，成功复现 `Account selected → cause=cancelled code=execution_indeterminate → cause=channel_closed reason=downstream_json_write`，确认一次上游调用和一个 unknown attempt。说明该顺序也可出现在已准入后下游主动取消，已断开连接无法再接收 JSON；不能据生产同序日志唯一归因为入站读取期限，也不能推断未准入。

A 最后复核补充：原先只用总期限处理停滞不满足本任务的进度预算要求；图片上传现在开始/每块背压拉取更新 progress_idle，EOF 切换 first_response，早到有效事件优先。补充构建通过、ExecutionBudgetTests 四测试通过、最终真实图片上传七场景通过（含 4 秒进度停滞与 12 秒总期限的持续慢传），随后三个账号池图片协议测试再定向通过。完整 Swift 轮次没有重跑，此增量只声明上述定向覆盖。

最终脚本轮次在已通过 29 项后，`verify_migration_readiness.py` 的另一旧图片 fake（Responses SSE）失败；改为原生图片完成事件/created 后该脚本重跑通过，只续跑后续未执行项，没有重复此前通过的 29 项。详见验证清单。

最终结果：44/44 backend 脚本最终通过；完整 Swift 轮次及修正后定向覆盖的准确结果见 [验证](verification.md)。最终 Swift 格式、文档、架构、分片及差异隐私检查通过。未执行 Linux/Docker 或真实提供者/客户端验证，未推送/开 PR。
