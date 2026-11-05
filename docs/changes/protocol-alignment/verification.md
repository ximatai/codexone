# 协议对齐验证

记录合成提供者与本地传输验证的范围，不替代真实订阅账号兼容结论。

## 当前业务边界

共享正文预算由 48 MiB 放宽到 64 MiB，单正文仍为 32 MiB。GIF/SVG 默认沿图片启用与有效模型授权，不再有逐账号确认字段；普通 SVG 使用上游默认编写模型。当前固定开源 Codex 工具未暴露独立 SVG 编写模型，显式非 null svg 对象在派发前拒绝；这不是对所有 Desktop 版本的运行结论。

## 本地证据

2026-11-05，macOS arm64、Swift 6.4.2：

- 全量 Swift 测试 471 项通过（Core 7、Runtime 67、EndToEnd 88、Adapters 309）。包括两个最大正文同时占用 64 MiB、第三个等待释放、队满/超时/取消、WS 断连及溢出恢复、图片权限/模型范围、默认 GIF/SVG、独立 SVG 模型拒绝与关键重复参数检测。
- `verify_images.py` HTTP/websocket 配置矩阵通过：无额外配置的 GIF/SVG、普通模型与 Key 权限拒绝、重复参数无派发、畸形/空/错误/混合输出和媒体类型失配拒绝、可信用量保留，以及两路 32 MiB 占满后排队上传与断连释放。另对 svg_usage 独立编写用量保留 partial/unknown，避免仅凭图片计数完整结算。
- `verify_upstream_ws_body_limit.py` responses/codex-subscription 真实套接字矩阵通过：两路最大正文占满预算时 WS 仅发大帧头等待，释放后继续成功；现有 1009/413、断流、不重放与账本责任保持。
- `measure_upstream_ws_body_limit.py` 的独立进程、fake provider、约 20 ms ps RSS 采样：17 MiB 单请求峰值约 99.80 MiB，32 MiB 单请求约 169.97 MiB，两路 32 MiB 约 285.36 MiB；空闲约 20.8 MiB。仅网关 RSS，排除 Python 客户端/提供者；不是 Linux 容器容量证明。
- 严格格式、文档、架构边界及 44 个脚本分片覆盖检查通过。只读复核确认移除格式门槛未绕过现有图片权限，响应与重复参数保护仍在。

## 再次复盘发现的覆盖缺口

2026-11-05 两名 subagent 只读复盘并由主代理核对代码：

- Responses 图片工具允许 GIF/SVG 请求，但其完成结果经 imageResult 使用参考图的 ImagePayload 校验，只接受 PNG/JPEG/WebP。现有 fake provider 的该用例返回 PNG，未验证真实 GIF/SVG 字节；原生 Images 结果路径不受同一校验器限制。
- Responses 的独立 svg_usage 尚未套用原生 Images 的 partial/unknown 保护；如果提供者返回该结构，现有图片/宿主计数可能被视为完整证据。此为代码条件推导，不代表真实提供者已返回该结构。
- 两个每连接 WebSocketInbox 复用了共享预算常量，隐式从 48 MiB 增至 64 MiB，超出提案范围；需拆分并保持队列原上限。

本轮未修改服务端实现或新增运行测试。以下既有通过结果仍有效，但不足以证明上述边界正确；PR 已退回草稿，补齐任务后再发布。

## Linux 与发布门禁

代码与测试脚本提交 `d6229aa` 的 Linux amd64、Swift 6.4.1 [Verify 42003725482（第 2 次）](https://github.com/ximatai/codexone/actions/runs/42003725482/attempts/2) 全部成功：构建、全量 471 项 Swift 测试、4 个分片共 44 个协议脚本及文档门禁。首次遇到既有 LAN 回滚测试的临时端口占用，失败任务复跑后通过；未修改生产期限或启动行为。

两路最大正文持有时，/proc 的进程 RSS 高水位为 responses 398944 KiB（约 389.59 MiB）、codex-subscription 405464 KiB（约 395.96 MiB）。只统计网关进程，不包括 fake provider/Python 客户端；这是该合成场景的峰值，不代表所有负载或进程 RSS 硬上限。夹具在建立 WS 连接前准备大正文，逐连接发送并确认派发，保留 10 秒首 create 期限。

最后仅补充此验证记录，代码与受测提交一致；自动复跑结果仍以 [PR #98 检查](https://github.com/ximatai/codexone/pull/98/checks)为准。

没有执行真实付费图片探测或修改线上配置；合成 GIF/SVG 只证明传输、封套、授权及结算，不证明实际格式/账号可用。UI 行为未变。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [验证约定](../../development/verification.md)
