# 协议对齐验证

记录合成提供者与本地传输验证的范围，不替代真实订阅账号兼容结论。

## 当前业务边界

共享正文预算由 48 MiB 放宽到 64 MiB，单正文仍为 32 MiB。GIF/SVG 默认沿图片启用与有效模型授权，不再有逐账号确认字段；普通 SVG 使用上游默认编写模型。当前固定开源 Codex 工具未暴露独立 SVG 编写模型，显式非 null svg 对象在派发前拒绝；这不是对所有 Desktop 版本的运行结论。

## 本地证据

2026-11-05，macOS arm64、Swift 6.4.2：

- 全量 Swift 测试 470 项通过（Core 67、Runtime 88、入口 7、Adapters 308）。包括两个最大正文同时占用 64 MiB、第三个等待释放、队满/超时/取消、WS 断连及溢出恢复、图片权限/模型范围、默认 GIF/SVG、独立 SVG 模型拒绝与关键重复参数检测。
- `verify_images.py` HTTP/websocket 配置矩阵通过：无额外配置的 GIF/SVG、普通模型与 Key 权限拒绝、重复参数无派发、畸形/空/错误/混合输出和媒体类型失配拒绝、可信用量保留，以及两路 32 MiB 占满后排队上传与断连释放。
- `verify_upstream_ws_body_limit.py` responses/codex-subscription 真实套接字矩阵通过：两路最大正文占满预算时 WS 仅发大帧头等待，释放后继续成功；现有 1009/413、断流、不重放与账本责任保持。
- `measure_upstream_ws_body_limit.py` 的独立进程、fake provider、约 20 ms ps RSS 采样：17 MiB 单请求峰值约 99.80 MiB，32 MiB 单请求约 169.97 MiB，两路 32 MiB 约 285.36 MiB；空闲约 20.8 MiB。仅网关 RSS，排除 Python 客户端/提供者；不是 Linux 容器容量证明。
- 严格格式、文档、架构边界及 44 个脚本分片覆盖检查通过。只读复核确认移除格式门槛未绕过现有图片权限，响应与重复参数保护仍在。

## Linux 与发布门禁

最终代码的 Linux amd64、Swift 6.4.1 构建、全量 Swift 与 4 个分片共 44 个协议脚本由 [PR #98 检查](https://github.com/ximatai/codexone/pull/98/checks)记录；必须成功才可合并发布。真实套接字用例会在两个最大正文持有时输出 /proc 的进程 RSS 高水位，供部署容量评估。历史提交 fb4f557 的全绿结果不能替代当前预算与默认格式行为的验收。

没有执行真实付费图片探测或修改线上配置；合成 GIF/SVG 只证明传输、封套、授权及结算，不证明实际格式/账号可用。UI 行为未变。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [验证约定](../../development/verification.md)
