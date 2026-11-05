# 协议对齐验证

记录合成提供者与本地传输验证的范围，不替代真实订阅账号兼容结论。

## 已完成

2026-11-05，macOS arm64、Swift 6.4.2：

- 全量 Swift 测试 472 项通过（Core 68、Runtime 88、入口 7、Adapters 309）。包含容量等待 FIFO/上限/取消/超时、WS 断连和溢出恢复、逐账号图片路由、持久准入复核、旧记录读取及关键参数重复检测。
- `verify_upstream_ws_body_limit.py` 的 responses/codex-subscription 真实套接字矩阵通过。包括两个 HTTP 执行占满预算时，native WS 仅发大帧头等待、释放后继续发送并成功完成；原 1009、413、断流、不重放及账本责任回归通过。
- 最终 `verify_images.py` 的 HTTP/websocket 配置矩阵通过：非流式扩展 generation、逐账号约束、未验证入口与重复参数无派发、畸形/空/错误/混合输出与媒体类型失配拒绝、可信用量保留，以及真实排队上传与断连释放。完整 `verify.sh --backend` 的 44 个后端脚本通过。
- 文档检查、Core 架构边界、44 个后端脚本分片覆盖、Swift 严格格式和差异空白检查通过。
- 两个只读评审分别检查连接/任务寿命与图片能力边界；发现的期限竞争、入口范围、单身份 ID 兼容、结果校验与重复参数解析问题均已加入修正和回归。

## Linux 与发布局限

- 原生 Linux amd64、Swift 6.4.1：代码提交 `fb4f557` 的 [Verify 41995986606](https://github.com/ximatai/codexone/actions/runs/41995986606) 全部成功，包含构建、全量 Swift 测试、4 个分片共 44 个协议脚本及文档门禁。后续仅补充此验收记录，源代码与受测提交一致。
- 合成 GIF/SVG 用例只验证参数、传输、路由、结果封套与结算，不能证明真实格式或账号能力。尚未据此配置任何真实账号确认；未执行真实付费图片探测。
- 未修改线上配置或部署版本。无 UI 行为变化；不以 macOS 结果代替 Linux 原生容量/生命周期验证。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [验证约定](../../development/verification.md)
