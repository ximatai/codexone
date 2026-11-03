# 大请求后的内存保留

记录本次内存修复的方案、验收与尚待 Linux 镜像确认的边界。

## 目标与根因

按运维规范 O11/O14，在不改变传输、大小限制、准入和结算责任的前提下，降低大请求结束后的常驻内存。现有证据指向 Linux glibc 多 arena 与大块分配保留：默认配置随可用核数放大，限制 arena、固定 mmap/trim 阈值显著降低峰值和空闲占用。该结论是合成测量的归因，未逐笔跟踪 allocator，不将全部 RSS 都归因于泄漏。

另外，HTTP 接收元组、解构局部值、route 参数和 WS 正文存储会在解析后继续持有原始 Data。ResponseRequest 已拥有解析结果，最后一次原字节使用后可以清空原正文；预算租约仍由原请求/turn owner 释放，不以释放字节替代准入责任。

## 已有证据

维护者提供的 CI linux/amd64 镜像、假上游、Rosetta 转译结果，约 108 个 22–30 MiB 请求；除注明 4 GiB 外，容器限制为 768 MiB。数值单位 MiB。

| CPU / 限额 | 配置 | 峰值 | 空闲 |
| --- | --- | --- | --- |
| 14 核 / 4 GiB | 默认 | 962 | 763 |
| 14 核 / 768 MiB | 默认 | 约第 13 个请求后 OOM | — |
| 14 核 / 4 GiB | 三项参数 | 302 | 93 |
| 2 核 / 768 MiB | 默认 | 347 | 224 |
| 2 核 / 768 MiB | 仅 mmap 1 MiB | 283 | 92 |
| 2 核 / 768 MiB | 三项参数 | 280 | 67 |

三项为 `MALLOC_ARENA_MAX=2`、`MALLOC_MMAP_THRESHOLD_=1048576`、`MALLOC_TRIM_THRESHOLD_=16777216`，已有测量未见明显耗时退化。旧工具最后 20 个 64 KiB 请求全部 502，因此这些结果只支持大请求内存形态，不能证明小请求 WS 兼容或完整混合容量。

## 方案与边界

- 运行镜像 ENV 设置上述三项，Compose/安装模板继承镜像默认值。规范与安装指南说明升级、覆盖和容量边界。
- HTTP 将正文以 inout 传入 route，进入 route 前清空接收元组；ResponseRequest 构造后清空正文。WS 在 turn 内最后一次 create 解析后清空共享正文存储，不能提前调用会归还预算的 release()。首轮在握手、lane 与控制消息使用完毕后才清空。
- 整理独立镜像测量工具，参数化镜像、内存限制与 cpuset，先确保小请求真正走通 WS，并记录 HTTP/WS 假上游调用数。工具不进入需拉镜像的 CI 分片。
- 不改发送字节、HTTP 回退、最终编码 16 MiB 边界、RequestBodyLimits，不做原字节零拷贝、JSON 结构改造、mallopt、定时 malloc_trim 或 jemalloc。

## 验收、迁移与回退

运行一次完整后端验证及文档检查；利用现有真实 socket 合成验收覆盖发送字节、HTTP 回退、16 MiB 边界、32 MiB 入站限制、预算竞争、取消和控制消息。追加正文清空与租约独立性的测试。用本机已有镜像定位并复验工具，禁止本机构建 Linux 镜像。

无 schema、配置格式或持久数据迁移。镜像重建并重建容器后默认生效；旧容器不会自动获得 ENV。回退镜像恢复旧 allocator 默认，需重新评估内存限额；不改变 unknown/恢复屏障。macOS 不验证 glibc 效果，新镜像及原生 Linux、多核/弱宿主混合容量留待评审者使用 CI 镜像验收。Rosetta、cgroup 计量、假上游及短周期测试不能代表真实订阅、吞吐或最低宿主要求。

## 相关文档

[运维规范](../../reference/specs/operations.md) · [验证定义](../../development/verification.md)
