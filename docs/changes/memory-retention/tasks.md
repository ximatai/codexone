# 大请求内存保留任务

记录本次内存修复的方案、验收与尚待 Linux 镜像确认的边界。

- [x] 阅读项目规范并记录既有证据、根因假设与边界。
- [x] 配置运行镜像 allocator ENV，确认安装与 Compose 继承。
- [x] 清空 HTTP/WS 最后一次解析后的原始正文，保留租约 owner 与释放时机。
- [ ] 测试字节、回退、大小边界、预算与控制消息。
- [x] 整理镜像测量工具并定位小请求 502，用已有镜像复测。
- [x] 同步容量规范、部署和测量指南。
- [ ] 运行一次完整后端验证及文档检查，记录实际平台与局限。
- [ ] 评审者用 CI 新镜像验收 Linux glibc 效果及多核容量（本机不构建镜像）。

## 实际验证（2026-11-03）

本机 macOS；镜像测试使用已有 CI linux/amd64 镜像 `ghcr.io/ximatai/codexone@sha256:e62c59fdf8596da3e20e0db3f93d2ff5abdf7928a3c7e693875a191851e52aba`，Docker Desktop/Rosetta，不构建镜像、不访问真实提供者。

- 原工具 `MEMTEST_ROUNDS=0`：20 个小请求均为 502，假上游调用为零。单请求诊断确认代理主机名时隧道未收到 CONNECT；同一镜像仅改为容器内 IPv4 后 CONNECT/WS 200。不是假上游返回 502；网关在此环境的代理主机名连接失败仍是独立未决问题，未改解析/重试/回退语义。
- 整理后的工具，`--rounds 0 --final-idle-seconds 1`：21/21 个小请求 200、completed/DONE，上游 WS 21 次、隧道错误零、OOM 零。
- `--memory 768m --cpuset 0-1 --rounds 1 --idle-seconds 1 --final-idle-seconds 1` 与三项 allocator 覆盖：39/39 完成；HTTP 回退 18 次、WS 21 次、隧道错误及 OOM 零。空闲时间被缩短，仅作工具通路验收，不作为回稳或本次源码内存效果证据。
- 三项 `--env NAME=` 移除变量的快速检查通过，报告有效 allocator ENV 为空；故意用容器自身 loopback 作为不可达代理，首个 WS 探针返回 502，工具非零退出且保存失败报告，没有继续大请求或误报成功。
- `python3 -m py_compile scripts/measure_image_memory.py scripts/verify_upstream_ws_body_limit.py`、修改文件的 `swift format lint --strict`、`python3 scripts/backend_shards.py --check`、`python3 scripts/check_ci.py` 和文档检查通过。
- Compose 的 environment 无三项 MALLOC 键，init-install 原样复制 compose.yaml，launcher 不注入三项；镜像默认值不会被模板覆盖。
- `./scripts/verify.sh --backend` 已启动一次，结果待补；新增预算测试与原有字节/16 MiB/HTTP 回退/控制消息验收须以本次运行结果为准。

新运行镜像尚未构建；macOS 不验证 glibc。原生 Linux、多核 768 MiB、新源码释放原字节后的峰值/回稳和真实混合负载留待评审者验收。主机名失败已隔离至接入隧道前的名称/地址连接路径，但尚未精确区分 DNS、IPv6 选择及 NIO/Rosetta 行为；工具 IPv4 适配不是网关修复声明。

## 相关文档

[运维规范](../../reference/specs/operations.md) · [验证定义](../../development/verification.md)
