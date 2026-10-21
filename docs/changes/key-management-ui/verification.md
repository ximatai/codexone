# 验证与复盘

## 2026-10-22 · 主 Agent 本机验收

macOS arm64 / Swift 6.4 / Node 22.23.0 / Chrome 155.0.8059.85，独立临时状态与无凭证合成上游。

- `./scripts/verify.sh --backend`：边界、格式、构建、52 个 Swift 测试和全部进程/协议/Key 脚本通过，新增 `verify_admin.py` 的真实 session/CSRF/Origin/Host、Cookie、容量、登出/重启和静态路径验证通过。Swift 测试补过期、文件硬链接/可写/超量拒绝及不可变快照。
- `./scripts/verify.sh --web --chrome`：类型、生产构建和 3 个概览浏览器测试通过；新增回归后单独 `npm run typecheck` / `npm test` 通过，共 15 个 API/组件案例。新增覆盖不重发未知变更、CAS/安全错误、分页环、正文超时、一次性秘密到期、迟到复制完成和卸载取消。
- `python3 scripts/verify_admin_ui.py --binary .build/debug/codexone`：生产 SPA 接真实临时服务的 Chrome 操作通过，实际 Cookie 为 Secure/HttpOnly/Strict。创建后真实数据面按模型授权；并发策略修改产生 CAS 冲突；禁用时轮换后再启用，旧凭证失效、计数连续。提交后丢失响应只执行一次，需刷新核对；登出失败先清本页内容、明确重试，服务端撤销确认后才返回登录。
- 主 Agent 查看登录、编辑和列表 1440px 大屏截图；未发现遮挡、横向溢出或主要操作缺失。截图不包含凭证；无运行时/CSP 错误，不写 local/sessionStorage，核心 DB/WAL/进程输出未含本次管理/数据秘密。复制使用浏览器测试边界桩，不向系统剪贴板写测试凭证。

自我复盘：禁用 Key 应能先轮换再启用，已使轮换保留 enabled 并同步 I12/A11；不会为准备新凭证短暂激活旧凭证，也不使用撤销审计预留。写入响应丢失与登出失败分别核对真实服务状态，未用 helper 成功推导外部结果。静态资产只在启动加载安全快照，不构成任意文件服务器。

此记录不代表 Desktop UI/恢复契约、真实账号 OAuth/刷新/额度、图片权限、账号池、生产部署或完整 M3 验收。提交后独立 review 与同快照 Linux 验证尚待执行。
