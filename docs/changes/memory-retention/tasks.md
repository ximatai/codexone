# 大请求内存保留任务

记录本次内存修复的方案、验收与尚待 Linux 镜像确认的边界。

- [x] 阅读项目规范并记录既有证据、根因假设与边界。
- [x] 配置运行镜像 allocator ENV，确认安装与 Compose 继承。
- [x] 清空 HTTP/WS 最后一次解析后的原始正文，保留租约 owner 与释放时机。
- [x] 测试字节、回退、大小边界、预算与控制消息。
- [x] 整理镜像测量工具并定位小请求 502，用已有镜像复测。
- [x] 同步容量规范、部署和测量指南。
- [x] 执行一次完整后端入口，恢复缓存后分阶段完成同一组检查及文档检查，记录实际平台与局限。
- [ ] 评审者用 CI 新镜像验收 Linux glibc 效果及多核容量（本机不构建镜像）。

## 实际验证（2026-11-03）

本机 macOS 27.2 arm64、Apple Swift 6.4.2（CI 固定 6.4.1）；镜像测试使用已有 CI linux/amd64 镜像 `ghcr.io/ximatai/codexone@sha256:e62c59fdf8596da3e20e0db3f93d2ff5abdf7928a3c7e693875a191851e52aba`，Docker Desktop/Rosetta，不构建镜像、不访问真实提供者。

- 原工具 `MEMTEST_ROUNDS=0`：20 个小请求均为 502，假上游调用为零。单请求诊断确认代理主机名时隧道未收到 CONNECT；同一镜像仅改为容器内 IPv4 后 CONNECT/WS 200。不是假上游返回 502；网关在此环境的代理主机名连接失败仍是独立未决问题，未改解析/重试/回退语义。
- 整理后的工具，`--rounds 0 --final-idle-seconds 1`：21/21 个小请求 200、completed/DONE，上游 WS 21 次、隧道错误零、OOM 零。
- `--memory 768m --cpuset 0-1 --rounds 1 --idle-seconds 1 --final-idle-seconds 1` 与三项 allocator 覆盖：39/39 完成；HTTP 回退 18 次、WS 21 次、隧道错误及 OOM 零。空闲时间被缩短，仅作工具通路验收，不作为回稳或本次源码内存效果证据。
- 最终工具的 `--proxy-resolution hostname` 复现 502/零 CONNECT/零上游，非零退出并保存报告；默认 `ipv4` 模式的两次 WS 探针全部完成。
- 三项 `--env NAME=` 移除变量的快速检查通过，报告有效 allocator ENV 为空；故意用容器自身 loopback 作为不可达代理，首个 WS 探针返回 502，工具非零退出且保存失败报告，没有继续大请求或误报成功。
- `python3 -m py_compile scripts/measure_image_memory.py scripts/verify_upstream_ws_body_limit.py`、修改文件的 `swift format lint --strict`、`python3 scripts/backend_shards.py --check`、`python3 scripts/check_ci.py` 和文档检查通过。
- Compose 的 environment 无三项 MALLOC 键，init-install 原样复制 compose.yaml，launcher 不注入三项；镜像默认值不会被模板覆盖。
- `./scripts/verify.sh --backend` 执行一次，在依赖获取阶段因 SwiftPM 缓存 `maintenance.lock` 缺失、反复重取 NIO 而中止（退出 143，尚未编译）；首次构建阶段重试也在依赖恢复前中止。仅在当前工作树重建 NIO 本地镜像仓库，使用依赖缓存中的锁定 revision，再执行 `swift package resolve --skip-update` 成功，未改 Package.resolved。
- 随后 `./scripts/verify.sh --backend-build` 通过：严格格式、构建、四个 targets 共 434 个 Swift 测试（66 + 83 + 7 + 278），包括新增正文存储与预算独立性测试。构建有既有文件的弃用等警告，无新增修改文件警告。`./scripts/verify.sh --backend-scripts all` 全部 39 项通过（退出 0），包括两种契约下新增 HTTP/首轮 WS 预算挂起测试，以及精确字节、16 MiB 边界、HTTP 回退、32 MiB 入站、取消、控制原字节、图片/共享预算、持久化与恢复验收；完整入口不报告为一次通过。

新运行镜像尚未构建；macOS 不验证 glibc。原生 Linux、多核 768 MiB、新源码释放原字节后的峰值/回稳和真实混合负载留待评审者验收。主机名失败已隔离至接入隧道前，且本次原生 macOS 构建同样复现：同一 IPv4 合成代理，`127.0.0.1` 为 200/一次 CONNECT/一次 WS，`localhost` 为 502/零 CONNECT/零上游调用。确认属于网关代理主机名连接问题，不能归为假上游或 Rosetta 专属故障。源码的单连接 owner 与 NIO 多地址候选初始化的交互值得单独核查，但未通过插桩确认，不作为已证实根因；本次不改网关语义。工具可用 `--proxy-resolution hostname` 保留故障通路，默认 IPv4 适配不是网关修复声明。

## 相关文档

[运维规范](../../reference/specs/operations.md) · [验证定义](../../development/verification.md)
