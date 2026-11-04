# 慢上游修复任务

记录独立提交与本地合成验收，真实上游不在本任务范围。

- [x] A：图片上传 EOF 后启动首响应期限；真实慢传、停滞与取消验收。
- [ ] B：有界媒体类型诊断及 streaming edits 完整 JSON 兼容。
- [ ] C：降低独立 Responses HTTP 路由阈值；说明为何不重试中断上传。
- [ ] D：非流式 generations 上游流聚合及输出/用量/错误/截断验收。
- [ ] E：真实 HTTP 慢入站复现、未映射原因诊断及可写 JSON 错误。
- [ ] 最后一次完整 macOS backend 验证与差异隐私检查。

2026-11-04 macOS：`swift build --product codexone -j 12` 通过；`python3 scripts/verify_upload_deadline.py --binary .build/debug/codexone --transport images` 五场景通过。测试脚本首次配置混用静态/托管 Key 导致启动失败，第二次慢读节奏误用 WS 值触及总期限；修正测试配置/节奏后完整重跑五场景通过。

## 相关文档

[提案](proposal.md) · [协议](../../reference/specs/protocol.md)
