# 发行 CI 加速任务

跟踪工作流结构与完整性检查；Linux 执行和耗时由维护者在 CI 验收。

## 实现与静态验证

- [x] 拆分一次优化构建、四分片、TLS/安装与最终 gate，保留发布摘要链。
- [x] 加入不缓存验证结果的优化构建缓存及安全失效规则。
- [x] 扩展 CI 策略检查与失败回归测试，同步发行和验证文档。
- [x] 执行本地工作流、发布政策与文档检查，记录实际结果。

2026-11-01，macOS：actionlint 1.7.7、`python3 scripts/check_ci.py`、`python3 scripts/test_check_ci.py`（8 项测试，含 gate 64 组合、四种缓存模式的 Docker 记录桩、构建失败清理和三处归档篡改）、`python3 scripts/test_prepare_release.py`（5 项）、`python3 scripts/backend_shards.py --check`（34 项）、`python3 scripts/check_architecture.py`、`python3 scripts/check_docs.py`、`git diff --check` 通过。实际 `prepare_release.py --dry-run` 在临时目录产出政策文件成功。未运行本地 Linux 镜像构建、Swift 产品构建或远端工作流；耗时/内存与 Linux 合成接口验收仍待 CI。

## CI 验收

- [ ] 维护者运行冷缓存与热缓存 dry-run，比较构建、最长分片、交接与总耗时，记录峰值内存/失败。
- [ ] 验证任一分片/TLS/安装失败或取消均阻断 gate 与 publish；验证归档/二进制 hash 不符失败。
- [ ] 首次 tag 发布核对镜像 ID、registry digest 和 attestation；在稳定规范中归纳后回收本目录。

## 相关文档

[提案](proposal.md) · [验证约定](../../development/verification.md)
