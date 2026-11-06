# 原生非流式生成任务

跟踪原生生成的请求保真、协议回归与候选验收。

- [x] 确认同账号 JSON 基线和候选范围。
- [x] 实现传输选择与原生图片回归。
- [x] 验证慢响应、取消和用量结算。
- [x] 通过 Linux CI 与候选验收。

## 本机验证（2026-11-06）

macOS arm64、Swift 6.4.2 下后端构建与 507 项 Swift 测试通过。真实 socket Images 测试覆盖两个端点前缀、两种配置的上游 Responses 传输、非流式原字节、慢 JSON、停滞、截断、客户端断开、用量及单次派发。合成提供者另行返回 SSE，以保留兼容聚合的回归覆盖。

## 候选验收（2026-11-06）

[Linux Verify](https://github.com/ximatai/codexone/actions/runs/42155376905) 与 [v0.26.11-rc.2 发布验证](https://github.com/ximatai/codexone/actions/runs/42157183558) 通过，包括优化镜像的混合容量检查。候选使用相同订阅账号和固定验收 Key，按已验证的 CLI 请求形状发起普通与较重的非流式生成。上游均返回 JSON，客户端收到 PNG 和用量，账本各完整结算一次。主动在响应头前断开后仅保留一条取消且结果未明的记录。实际提供者对照限于这一订阅路径和样本。

## 相关文档

[提案](proposal.md) · [协议规范](../../reference/specs/protocol.md)
