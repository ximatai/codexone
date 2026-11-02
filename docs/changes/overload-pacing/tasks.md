# 任务：上游过载节流

契约见 [proposal](proposal.md)。

- [x] 进程内连续过载计数与节流期计算。
- [x] 统一账号选择：优先非节流账号，全部节流时有界等待并重新准入，HTTP/WebSocket 一致。
- [x] 取消、并发上限、Retry-After、429/401 不变的测试。
- [x] 规范同步与完整后端验证。
- [x] 评审修复：软偏好短暂过载等待、长过载/429/并发满回退，定向与完整后端验证。
- [ ] 维护者评审、发版与线上观察。

## 本地验收（2026-11-02）

macOS arm64、Swift 6.4.2，全部使用合成账号与本地 HTTP/SSE/WebSocket 提供者：

- 定向 `swift test -j 12 --filter 'accountPool|overload'` 通过（27 项），覆盖软偏好 1 秒过载后等待并重选原账号、长过载/429/并发满回退、等待前 Key 检查，以及连续升级、成功清零、重启、可信 Retry-After 并发截止、选择/固定账号、readiness、等待上限、断连/取消/期限及释放后并发复核。
- `python3 scripts/check_docs.py` 通过。
- `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 通过：386 项 Swift 测试、34 个后端验收脚本；包含格式与架构检查。

未连接真实订阅/提供者或部署实例，未构建 Linux 镜像；真实客户端与线上观察仍待维护者验收。精度处理见 I20：进程内微秒截止，持久 epoch 秒向上取整，重启后至多额外不足 1 秒；无 schema 变化。

## 相关文档

[文档导航](../../README.md)
