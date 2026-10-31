# 首页需要处理提醒验证

日期：2026-10-31。平台：macOS arm64；全部使用本机合成数据，无真实订阅、部署、Docker 或 Linux 验证。

## 覆盖

- 账号授权/健康冷却、额度89%/90%/98%、新鲜期与空/失败观测；启用Key七天边界、禁用/无限额Key、当日治理请求与预算占用。
- 滚动60分钟准入及失败率（19次不触发、10%边界、取消不计失败）、全时间unknown；真实SQLite快照、来源损坏、排序/50条截断。
- 管理认证/来源、GET不要求CSRF、no-store、繁忙429及无凭证响应；低盘退让仍可见critical提醒。
- 协议集合32项、长度/字符、去重/首次时间、溢出、并发安全及真实WS/未知头名到提醒链路，仅名称不含值。
- 首页critical/warning/空/错误/重试与目标页面、导航可访问红点；15秒刷新/暂停/手动刷新；桌面及长名称窄屏走查。

## 结果

按要求，失败后仅重跑失败检查，再续跑尚未执行的入口；未重复已通过的完整检查。

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---|---|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend`（首次编译） | 1 | 84.2秒 | 新DTO的detail公开可见性与内部JSON类型不匹配，已将detail改为模块内部；依赖版本未变 |
| 同上（编译修正后） | 1 | 51.4秒 | 格式/架构/构建通过；258项Swift中257通过，1项损坏观测夹具错误（全可空类型的`{}`是合法空观测） |
| `swift test --disable-sandbox --jobs 12 --filter attentionReaderAccountsUseNonSecretQuotaAndHealthSnapshots` | 0 | 8.6秒 | 夹具改为类型错误的JSON后1项通过；258项已逐项通过（含10项attention、3项协议集合） |
| `bash artifacts/admin-attention/backend-remainder.sh` | 0 | 456.8秒 | runner提取verify.sh后端函数中Swift测试之后的原始命令，从verify_storage_pressure至verify_migration_cutback原顺序续跑 |
| `./scripts/verify.sh --web --chrome` | 1 | 23.2秒 | lint/format/typecheck/build、Vitest96项通过；Chrome11/12通过，新增定位器同时匹配导航与提醒区 |
| `cd web && npx playwright test tests/e2e/overview-phase2.spec.ts --project=chrome` | 0 | 5.0秒 | 改为精确region定位；评审修正后再次通过，含128字节名称、390px无溢出和1440×900截图；其余11项无需重复 |
| `cd web && npm test -- --run src/features/system-status/AttentionPanel.test.tsx` | 0 | 0.7秒（测试报告） | 4项通过；评审文案修正后的定向验证 |
| `cd web && npm run build` | 0 | 0.9秒 | 生产SPA构建通过 |
| `python3 scripts/verify_admin_ui.py --binary .build/debug/codexone` | 0 | 12.7秒 | 真实本机Chrome登录/管理/CSP及新增首页提醒空态通过 |
| `python3 scripts/check_docs.py` | 0 | 0.04秒 | 196份Markdown、本地链接与任务结构通过 |

首次依赖完整历史下载被主动停止，改用本worktree忽略目录内的同锁定提交浅镜像；不修改Package.resolved，不提交机器相关配置。上述84.2秒从依赖准备后的完整后端入口计时。

## 界面与评审

1440×900合成首页截图位于忽略的 `artifacts/admin-attention/overview.png`，含critical、warning与导航红点。前端subagent评审未发现P0/P1；两项P2已修复：到期文案涵盖已过期Key，长无空格名称换行。Chrome定向验证桌面与390px宽度，页面无横向溢出。

## 数据来源与边界

账号从现有accounts公开元数据、account_quota观测和account_model_health冷却汇总；Key从managed_keys公开元数据及当日attempts治理占用汇总；执行从attempts的准入时间/终态及全时间unknown汇总。所有持久源共用现有SQLiteUsageReader的单在途、快照、扫描预算与取消门禁，不解密账号凭证。存储来自现有StorageMonitoring快照；协议来自入口持有的有界进程内集合。

Linux verification、主Agent最终评审与部署测试实例由主Agent后续执行。本次不推送或开PR，不改变schema、阈值配置、通知或历史告警行为。
