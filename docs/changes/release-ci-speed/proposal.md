# 加速发行 CI

将优化构建、合成验证与发布交接拆分，以缩短 Release 的关键路径，保持每次运行验证同一镜像与二进制。

## 证据与方案

成功 dry-run [41308814290](https://github.com/ximatai/codexone/actions/runs/41308814290) 的验证 job 为 23分51秒：优化编译 822.4秒、ExecutionProbe 10秒、串行脚本 429.4秒；TLS 26秒、安装 44秒。仅分片仍受编译限制。采用一次构建、四个后端分片、独立 TLS/安装、最终 gate；Release 专用 BUILD_JOBS=2，保留 Dockerfile 默认单并发，峰值内存与加速效果待 CI 测量。

优化构建使用独立 BuildKit 层缓存，按 Dockerfile 与源码 revision 分 key，允许恢复同 Dockerfile 的前一次缓存。缓存只加速构建，不保存验证结果；每次重新执行所有分片、TLS 和安装。缓存缺失须能冷构建。SwiftPM 可写 cache mount 不跨运行导出，避免引入 PR 的 debug .build；许可证与产品二进制在同一 RUN 输出，避免层命中后依赖空 cache mount。相同源码预期复用编译层，源码变更仍可能完整重编译，不能承诺增量收益。

## 契约与验收

依据 [O06/O08/O11](../../reference/specs/operations.md) 和[发版规则](../../development/releasing.md)，优化二进制必须来自本次候选镜像，TLS 同样直接复制候选镜像的二进制与 SPA。原 verification target 的全部 18 项检查须属于复用的四分片；新增覆盖来自现有 PR 分片，不新增 Swift 单元测试要求。无网络的合成验证、安装约束与 TLS 约束保留。

最终 gate 拒绝失败、取消或跳过的任一必需 job；校验构建输出的镜像归档 hash 后才转交 verified artifacts。publish 只依赖 gate，校验同一归档 hash、image ID、推送后回拉 digest，并对推送 digest 生成证明；不重建镜像。所有消费者 checkout 构建解析出的不可变 revision。缓存产出的字节也必须通过本次完整验证，缓存不构成独立来源证明。

## 成本、迁移与回退

无产品协议、schema、数据或恢复语义变化。代价为更多 runner 分钟、重复 SDK 拉取、缓存与制品传输；受并发额度和缓存命中率影响。目标约 10 分钟须由维护者对冷/热 dry-run 测量，失败或内存压力时可回退 Release 的 BUILD_JOBS=1 或禁用缓存；仍保留完整验证 gate。恢复串行工作流不会改变产品数据。

## 相关文档

[任务](tasks.md) · [验证约定](../../development/verification.md) · [变更约定](../README.md)
