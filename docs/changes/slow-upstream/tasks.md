# 慢上游修复任务

记录独立提交与本地合成验收，真实上游不在本任务范围。

- [x] A：图片上传 EOF 后启动首响应期限；真实慢传、停滞与取消验收。
- [x] B：有界媒体类型诊断及 streaming edits 完整 JSON 兼容。
- [x] C：降低独立 Responses HTTP 路由阈值；说明为何不重试中断上传。
- [x] D：非流式 generations 上游流聚合及输出/用量/错误/截断验收。
- [ ] E：真实 HTTP 慢入站复现、未映射原因诊断及可写 JSON 错误。
- [ ] 最后一次完整 macOS backend 验证与差异隐私检查。

2026-11-04 macOS：`swift build --product codexone -j 12` 通过；`python3 scripts/verify_upload_deadline.py --binary .build/debug/codexone --transport images` 五场景通过。测试脚本首次配置混用静态/托管 Key 导致启动失败，第二次慢读节奏误用 WS 值触及总期限；修正测试配置/节奏后完整重跑五场景通过。

## 相关文档

[提案](proposal.md) · [协议](../../reference/specs/protocol.md)

2026-11-04 B：`swift build --product codexone -j 12` 通过；`python3 scripts/verify_images.py --binary .build/debug/codexone` 两种配置（HTTP/WS）全部通过，含真实 HTTP 的 JSON→SSE 单图/多图、无效/混合结果与媒体类型拒绝，既有错误、许可竞争、断开、用量和预算验收。随后修正空媒体类型解析的索引风险并重新构建；该修正的运行测试随最终完整验证执行。

2026-11-04 C：`swift build --product codexone -j 12` 通过；真实 WS 上传五场景与新增帧中断场景通过，单派发/unknown/无健康惩罚。大小边界矩阵覆盖 12/16 MiB 的边界前/等于/后及 HTTP/SSE/native；Responses 合约通过，订阅合约仍在运行，最终结果在下方记录。普通写失败无法提供未执行证明，因此按任务条件不新增 HTTP 重试。

2026-11-04 C 补充：完整 `verify_upstream_ws_body_limit.py` 两合约通过。D：`swift build --product codexone -j 12` 与 `verify_images.py` 两配置通过。验收包含两客户端前缀、非流式 JSON 字段/状态/用量对等、原生 SSE 原字节、JSON 转完成事件、HTTP 错误、流内错误、终态前截断、终态后残片、重复终态、缺失时间戳、空图片、部分用量、取消、许可/预算竞争。D 的 JSON 对等为合成原生格式的字段和值，不能证明真实上游所有未知字段可由 SSE 恢复；缺失字段不伪造，真实格式仍未验证。
