# 任务

追踪第一批客户端协议保真改动与验证。

- [x] 确认第一批协议保真范围和 Realtime 优先级。
- [x] 实现并验证 Responses 模型头与 Retry-After。
- [x] 实现并验证未知字段与原生 Images 流式错误。
- [x] 同步规范与 Realtime 兼容边界。
- [x] 运行本机后端验证并记录平台和范围。

- [x] 合并前运行 Linux CI。
- [x] 核对候选运行代码与已发布镜像，复用既有生成和断开验收。
- [ ] 补齐同一客户端、同一订阅账号的原生参考图编辑对照。

## 实际验证（2026-11-06）

macOS arm64、Swift 6.4.2 上通过后端构建、严格格式及 507 项 Swift 测试。九项本地 socket 检查覆盖 JSON 顺序、原生图片、原生 WS、上游事件、辅助接口、协议拒绝、可选推理、WS 大请求与请求参数。测试使用合成上游，验证了 HTTP 模型头与过滤、HTTP/SSE/原生 WS 和桥接错误等待提示、上游升级拒绝、未知字段、图片事件和不重放。旧推理测试原先要求删除全部 null，已更新并重跑，分别验证已知字段省略和未知字段保留。生产环境和真实提供者留待发布验收。

[Linux Verify](https://github.com/ximatai/codexone/actions/runs/42147986756) 已通过。当前候选的非流式 PNG 对照和断开证据见[原生生成验收](../native-image-json/tasks.md)。真实 Codex CLI 已验证原生 PNG 生成并保存，既有参考图编辑的接口证据仍需与真实客户端直连对照区分。

## 相关文档

[提案](proposal.md) · [协议规范](../../reference/specs/protocol.md)
