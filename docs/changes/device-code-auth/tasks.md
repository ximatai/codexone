# 任务：设备码账号授权

契约见 [proposal](proposal.md)。

- [x] 提供者设备码请求、轮询与兑换适配，合成 socket 失败路径测试。
- [x] 授权用例与 Runtime 轮询所有权、容量、期限、取消与停止。
- [x] 管理 API `method` 与流程状态读取，owner 隔离测试。
- [x] 前端默认设备码流程、备用回调切换与启用入口，浏览器验收。
- [x] 规范与指南同步，完整后端与前端验证。
- [ ] 维护者同意后的真实账号授权验收。

## 合成验收记录

2026-11-01，本地 macOS 27.2 / arm64，Swift 6.4.2、Node.js 22.22.0、npm 10.9.4。Node 实际版本较贡献指南的 22.23.0 低，未升级环境或依赖。未执行 Linux/Docker 构建，未调用真实 OpenAI/ChatGPT 端点。schema 保持 v10；流程只在内存，回退无需数据迁移。

- `swift format lint --strict --recursive Sources Tests Package.swift`、`python3 scripts/check_architecture.py`：通过。
- `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend`：通过，316 项 Swift 测试和 33 项进程、存储、协议及管理验收脚本。首次构建的测试 helper 访问级别问题修复后重跑该入口通过。
- `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-build`：最终版本构建与 316 项 Swift 测试通过。
- `swift test -j 12 --filter 'deviceSocket|deviceProvider|authorizationFlow|authorizationRejects|authorizationCapacity|reauthorizationPreserves'`：通过；最终构建后以同一 filter 加 `--skip-build` 连续运行 20 次，20/20 通过，每轮 4 项回调与 8 项设备码测试，共 240 次选中测试执行。本地忽略的记录在 `artifacts/device-code-auth/contract-final/round-*.log`。
- `npm --prefix web run lint`、`npm --prefix web run format:check`、`npm --prefix web test`：最终版本通过，151 项单测。
- `npm --prefix web run typecheck`、`npm --prefix web run build`：通过。
- `./scripts/verify.sh --web --chrome`：通过，生产构建及 39 项 Chrome e2e；后续状态一致性修正通过全部单测和设备码定向 e2e 复验。
- `npm --prefix web run test:e2e:chrome -- device-code-auth`：最终版本通过，1440×900 与 390×844，覆盖成功后明确启用、不可用切换回调、取消与倒计时到期；截图仅合成数据，已目视检查布局。
- `python3 scripts/verify_account_admin_ui.py --binary .build/debug/ExecutionProbe`：最终版本通过，真实 SPA、管理 API、Runtime、合成提供者与加密 SQLite/WAL；日志和数据库扫描未发现 user code、device_auth_id、token 或主密钥原文。
- `python3 scripts/check_docs.py`：通过。

设备码与回调使用同一流程容量、owner 和完成配额；创建、间隔等待、轮询与兑换都由 Runtime 结构化任务拥有。轮询测试使用可推进门控和注入的期限，收敛等待按单调时钟限制总耗时；自主到期测试等待实际网络退出，不以固定休眠后直接断言替代。回调成功、失败与兑换中的状态读取同样保持一致。

维护者真实账号验收仍待明确同意后执行；合成验证不证明实际订阅或生产 TLS 兼容。Playwright 按仓库既有配置放在 `web/tests/e2e`，未另建 `web/e2e`。

## 相关文档

[文档导航](../../README.md)
