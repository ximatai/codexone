# 参数拒绝诊断任务

跟踪分类、隐私诊断及真实协议验收，未通过项不计完成。

- [x] 在准入前记录处修正分类，保持执行内映射不变。
- [x] 为八类受限参数附固定私有 reason，保持公开错误契约。
- [x] 真实 HTTP/原生 WS 的零派发、零 attempt 与诊断分类验收。
- [x] 固定字段、日志隐私、null 与已有续接行为回归。
- [x] 定向验证与相关后端验收，记录实际平台、结果及局限。
- [x] 同步能力规范与公开状态，检查差异及新增文件。
- [ ] Linux CI 与发布后的实际诊断验收；本机验证不替代 Linux，合成验收不冒充线上已生效。

## 本机验证（2026-11-05）

macOS arm64、Swift 6.4.2；提供者全部为 loopback 合成服务，未调用真实订阅。

- 定向 `swift test -j 12 --filter 'ProtocolFailureDiagnosticsTests|poolNativeRequestParametersRejectBeforeFirstAdmissionOrUpstreamHandshake|poolHTTPBackendParameterDiagnosticsAreInvalidRequestsWithoutDispatch'` 通过：9 个诊断测试，2 个端到端测试（HTTP 测试分别运行 HTTP/WS 两种上游配置），包含实际 HTTP/WS 返回、SQLite 诊断、零 attempt、零派发/握手。
- 完整入口首次因系统 Bash 3.2 对空数组与 nounset 的兼容问题，在构建前退出；文档与架构检查已通过。以项目既有 `CODEXONE_SWIFTPM_DISABLE_SANDBOX=1` 选项填充参数数组、`CODEXONE_BUILD_JOBS=12` 重新运行完整 `./scripts/verify.sh --backend`，466 个 Swift 测试及 44/44 个后端脚本全部通过，该次完整命令退出码 0。此前的 Bash 入口失败不记为通过。
- 规范、STATUS 和未发布 CHANGELOG 已同步；新增私有 reason 不进入公开 envelope，历史诊断不重写。无 schema 或配置变化。

## 相关文档

[提案](proposal.md)
