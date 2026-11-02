# 任务：上游过载节流

契约见 [proposal](proposal.md)。

- [x] 进程内连续过载计数与节流期计算。
- [x] 统一账号选择：优先非节流账号，全部节流时有界等待并重新准入，HTTP/WebSocket 一致。
- [x] 取消、并发上限、Retry-After、429/401 不变的测试。
- [x] 规范同步与完整后端验证。
- [x] 评审修复：软偏好短暂过载等待、长过载/429/并发满回退，定向与完整后端验证。
- [x] 评审跟进：无其他健康候选最多等待 15 秒，软偏好最多等待 3 秒后改选；补齐 8 秒等待、20 秒 Retry-After 与短总期限验收。
- [x] 同步main的Token治理/UI及CI脚本，解决变更日志冲突。
- [x] 评审修复：等待归还finalizer票据，满并发冷却账号不参与等待期限选择；补充真实HTTP/WS与Token耗尽回归。
- [ ] 更新后验证、CI、维护者评审、发版与线上观察。

## 本地验收（2026-11-02）

macOS arm64、Swift 6.4.2，全部使用合成账号与本地 HTTP/SSE/WebSocket 提供者：

- 定向 `swift test -j 12 --filter 'overload|accountPool|accountRouting'` 通过（28 项，含参数化用例），覆盖单账号 8 秒假等待后转发、1 秒总期限结束 8 秒等待且不记健康故障、软偏好 2 秒等待并重选原账号与 4 秒/429/并发满回退、Retry-After 20 秒返回 503 与响应头及剩余 15 秒时 readiness/等待放行、等待前 Key 检查，以及连续升级、成功清零、重启、可信 Retry-After 并发截止、选择/固定账号、readiness、等待上限、断连/取消/期限及释放后并发复核。
- `python3 scripts/check_docs.py` 通过。
- `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 通过：387 项 Swift 测试、34 个后端验收脚本；包含格式与架构检查。

未连接真实订阅/提供者或部署实例，未构建 Linux 镜像；真实客户端与线上观察仍待维护者验收。精度处理见 I20：进程内微秒截止，持久 epoch 秒向上取整，重启后至多额外不足 1 秒；无 schema 变化。

## 相关文档

[评审验证](verification.md) · [文档导航](../../README.md)
