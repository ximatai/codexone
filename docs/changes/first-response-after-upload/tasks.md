# 任务

追踪上传期限变更的实现与合成验收。

- [x] 阅读约定与现有传输/期限责任，记录提案。
- [x] 实现上传完成计时与有界诊断。
- [x] 合成真实进程 HTTP/WS 矩阵、字节/账本/健康验收（10 项通过）。
- [x] 更新能力规范和公开状态。
- [x] macOS 定向验证、最终完整 backend verify 一次；记录限制与提交。

## 验证记录（2026-11-03）

平台：macOS arm64，Apple Swift 6.4.2。`swift build -j 12`、定向 `swift test -j 12 --filter ExecutionBudgetTests`（2 项）、文档/架构/Swift 格式检查通过。

真实 binary 合成提供者矩阵使用 28 MiB HTTP、12 MiB WS，首响应期限 2 秒；慢读前段超过首响应期限后快速读完 socket 缓冲尾部，避免把远端消费时刻误当成本机写入完成。另检查快读/慢读后静默、未读完、上传中取消；全部核对单 attempt、账本、无账号/模型健康惩罚、可完成上传的精确编码字节及无内容诊断。`CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 最终仅执行一次并通过（433 项 Swift 测试、39 个后端脚本）；期间未另起构建或修改实现。完整验证同时覆盖现有 HTTP JSON/SSE、原生 WS、桥接、1009 回退、续接、图片及取消/收尾行为。

限制：仅 loopback 合成数据，不代表真实提供者或客户端兼容；无 Linux 构建、部署或真实订阅。HTTP EOF 为 AHC 背压消费边界，WS 为 transport write future；两者均不能证明远端已读完。compact 与原生 Images 保留此前计时边界。

## 相关文档

[提案](proposal.md) · [协议规范](../../reference/specs/protocol.md)
