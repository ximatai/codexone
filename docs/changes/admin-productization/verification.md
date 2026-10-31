# 管理台产品化验证与交付

日期：2026-10-31。平台：macOS arm64。本记录仅针对本变更的合成验证，不代表真实订阅、部署或 Linux 验收。

## 命令结果

| 命令 | 退出码 | 关键结果 |
|---|---:|---|
| `swift build --disable-sandbox` | 0 | `Build complete!` |
| `swift test 2>&1 | tail -5` | 0 | 全部218项；末组 `Test run with 141 tests in 1 suite passed` |
| `./scripts/verify.sh --backend` | 0 | 文档/架构/格式、构建、全部Swift测试及全部loopback进程/协议/管理/迁移检查通过 |
| `cd web && npm run lint && npm run format:check && npm test && npm run build` | 0 | lint/格式/类型/构建通过；最新单元测试54项、15个文件通过（完整web入口再次执行）；主入口约465 kB |
| `./scripts/verify.sh --web --chrome` | 1 | 前置检查通过；5个浏览器用例均在Chrome临时进程启动时SIGABRT，未执行断言 |
| `./scripts/verify.sh --web` | 1 | 最新lint/格式/类型、54项单测和构建通过；5个浏览器用例因配套Chromium可执行文件未安装而无法启动 |
| `cd web && npm run test:e2e:chrome -- --list` | 0 | 5个测试，3个文件；仅证明测试可收集，不是浏览器验收 |
| `python3 scripts/verify_admin.py --binary .build/debug/codexone` | 0 | 新摘要及明细真实loopback接口、主体名、认证/跨来源拒绝、耗时与settled账本通过 |
| `swift test --disable-sandbox --filter keyUsageUsesUTC` | 0 | 最终夹具覆盖UTC边界、failed/unknown/在途、全时间最近使用、删除/未知主体、256/257上界、历史耗时null与结算不变 |
| `git diff --check` | 0 | 无空白错误 |

普通SwiftPM命令最初因本机 `sandbox-exec: sandbox_apply: Operation not permitted` 失败。按照brief允许，后续构建/测试使用 `--disable-sandbox`；完整后端入口通过仓库外临时PATH包装器给SwiftPM build/test/package追加该参数。没有修改Package、锁文件或验证入口。镜像依赖有既有identity警告，构建通过。

后端完整入口运行期间的最终小改动为更精确地在原生图片SSE解析出事件时记录首事件，以及加强摘要夹具；最终源码已重新构建，Swift全测/定向测试及图片loopback验证再次覆盖。没有凭证或真实账号调用。

## 已覆盖的行为

- options兼容保留ID数组，追加带主体名的选项；明细连接当前主体名，删除/未知为null。摘要只读、有界，使用既有reader寿命/单在途/扫描预算；认证和来源保护不变。
- 当日UTC左右边界、failed计数、unknown与在途待核对、全时间最近准入、费用缺失语义及256/257边界。
- 新执行的单调耗时与首事件观测；历史缺字段为null，原有费用、证据和结算语义保持。
- Vitest覆盖首页卡片/存储详情、共享金额换算/不限/缺失、术语、倒计时、24小时窗口、Key禁用取消与确认、详情内排空取消与确认、Key自动查询、主体名、耗时与请求ID复制。保留既有会话、未知写入锁、一次性秘密及查询失败覆盖。
- 新Playwright合成流程覆盖登录、1440首页、Key搜索/状态筛选、禁用取消/确认、自动查询、明细/复制、390宽度断言；既有浏览器覆盖与live脚本按新文案/确认流程更新，未删覆盖。

## 未完成与风险

- 浏览器验收没有完成。Chrome进程启动受本机执行环境限制；备用Chromium未安装。浏览器工具host不可用，电脑工具也未获准操作Chrome，因此无法补做1440/390截图走查或执行live UI脚本。须在可启动Chrome的环境重跑 `verify.sh --web --chrome`、`verify_admin_ui.py`、`verify_account_admin_ui.py`，并人工检查布局；不能把Vitest或测试收集当视觉验收。
- 未验证Linux、真实上游或部署；没有新增依赖、修改schema或使用真实账号。
- 待核对卡片是当日在途与unknown之和，链接跳到同一UTC当日的用量报告；报告单列两类状态。缺失用量不填零，金额为已观测估算下界。
- 24小时快捷区间采用已完成UTC小时，以满足现有查询的小时边界。排空仍允许已有身份关联续接；两项已在提案与界面解释。当前范围无新增必须由用户决定的产品问题。
- 所有改动均留在工作树，未暂存、未提交、未push、未开PR。STATUS与Package文件未修改。

## 文件清单与建议分组提交

以下为完整改动清单；建议主Agent按组提交，本执行者没有执行git add/commit。

### 后端与接口契约

建议英文提交信息：`feat(admin): add bounded key usage summaries and request timings`

- `Sources/CodexOneAdapters/ControlPlane/UsageAdminAPI.swift`
- `Sources/CodexOneAdapters/Images/NativeImageExecution.swift`
- `Sources/CodexOneAdapters/Persistence/SQLiteUsageQueries.swift`
- `Sources/CodexOneAdapters/Persistence/SQLiteUsageReader.swift`
- `Sources/CodexOneAdapters/Upstream/CompactResponseExecution.swift`
- `Sources/CodexOneAdapters/Upstream/HTTPResponseExecution.swift`
- `Sources/CodexOneAdapters/Upstream/WebSocketResponseExecution.swift`
- `Sources/CodexOneCore/Application/Execution/ExecutionCoordinator.swift`
- `Sources/CodexOneCore/Application/Execution/ExecutionOutcome.swift`
- `Sources/CodexOneCore/Application/Usage/UsageQueries.swift`
- `Tests/CodexOneAdaptersTests/UsageQueryTests.swift`
- `docs/specs/control-plane.md`
- `docs/specs/usage.md`
- `scripts/verify_admin.py`

### 管理前端与合成用例

建议英文提交信息：`feat(web): productize admin overview and management workflows`

- `web/scripts/live-accounts.mjs`
- `web/scripts/live-keys.mjs`
- `web/scripts/live-usage.mjs`
- `web/src/App.tsx`
- `web/src/features/account-management/AccountManagement.test.tsx`
- `web/src/features/account-management/AccountManagement.tsx`
- `web/src/features/account-management/AccountObservability.tsx`
- `web/src/features/account-management/QuotaWindowBar.tsx`
- `web/src/features/key-management/KeyEditor.tsx`
- `web/src/features/key-management/KeyLimitsSummary.test.tsx`
- `web/src/features/key-management/KeyLimitsSummary.tsx`
- `web/src/features/key-management/KeyManagement.test.tsx`
- `web/src/features/key-management/KeyManagement.tsx`
- `web/src/features/system-status/AdminOverview.test.tsx`
- `web/src/features/system-status/AdminOverview.tsx`
- `web/src/features/usage/UsageOverview.test.tsx`
- `web/src/features/usage/UsageOverview.tsx`
- `web/src/features/usage/UsagePage.tsx`
- `web/src/features/usage/api.test.ts`
- `web/src/features/usage/api.ts`
- `web/src/shared/presentation.test.ts`
- `web/src/shared/presentation.ts`
- `web/src/styles.css`
- `web/tests/e2e/admin-productization.spec.ts`

### 提案与验收记录

建议英文提交信息：`docs(admin): document productization decisions and verification gaps`

- `docs/changes/admin-productization/proposal.md`
- `docs/changes/admin-productization/tasks.md`
- `docs/changes/admin-productization/verification.md`

## 主 Agent 复核与大屏走查（2026-10-31）

- 本机原生 `./scripts/verify.sh --backend`：退出码 0，Swift 共 218 项。
- `./scripts/verify.sh --web --chrome`：退出码 0，vitest 54 项，Playwright 5 项。
- `verify_admin_ui.py` 与 `verify_account_admin_ui.py`（真实 Chrome）：均 PASS。执行者沙箱中无法启动浏览器，本轮由主 Agent 原生补跑。
- 1440×900 合成实例走查发现并修复的问题：
  - 管理端 CSP（`style-src 'self'`）会阻止 Mantine 为响应式 `SimpleGrid` 注入的样式，概览与用量页的卡片在大屏上退化为单列。改为静态 CSS 网格（`responsive-grid`）。
  - 概览把“今日运营概览”放在就绪信息之前。
  - 用量明细表的次要信息原为行内 `<small>`，文字挤在一起，改为分行显示并左对齐。
  - 账号详情中新旧两套窗口进度条重复显示，移除旧的。
  - 账号列表的陈旧判断与告警判断统一使用同一时钟。
  - 文案：费用无值时显示“费用：不可用”；从未使用的 Key 显示“从未使用”。
  - 相应地更新了 live/e2e/单元测试的断言（新列表也显示新鲜度，改用 `.first()`；进度条改为剩余比例）。
- 已确认可用：
  - 登录后首页 4 列卡片；
  - Key 搜索、状态筛选与今日用量列；
  - 从 Key 进入用量时按主体名自动查询；
  - 明细详情抽屉，含完整请求 ID、复制、首事件/总耗时与各项用量。


## 四项 P2 返工（2026-10-31）

- 范围仅 web 代码/测试与本记录；没有后端、依赖、STATUS 或其他规范改动，没有暂存或提交。
- 最近 24 小时首次查询固定已完成 UTC 小时的起止秒；翻页（含返回第一页）沿用窗口，重新查询或快捷区间查询重新计算。单测跨小时验证实际请求筛选经 `usageParameters` 后起止参数相同、游标变化，以及重新查询更新结束时间。
- 首页使用账号摘要的单调接收时间与 `freshForSeconds`，每 15 秒更新显示。fake timers 推进 300 秒验证 fresh 变 stale，unavailable 保持不可用；账号列表另测从未成功观测时不显示陈旧。
- 用量明细与首页存储抽屉设置 `lockScroll={false}`，生命周期维护外部 CSS 的 `management-overlay-open`；测试覆盖打开、关闭、重新打开和卸载清理。
- 全部 `web/src` 检索：全部 9 处 Modal/Drawer 均已显式关闭默认滚动锁；未发现响应式对象 props、`hiddenFrom`/`visibleFrom`、SimpleGrid/Grid、ScrollArea 或自定义 style 标签注入。额外修复首页账号卡片与用量请求 ID 两处内联 `overflowWrap`，统一为外部 `.wrap-anywhere`。既有 MantineProvider 保持 `withCssVariables={false}` / `withGlobalClasses={false}`，静态媒体查询网格保持不变。
- 最终执行 `cd web && npm run lint && npm run format:check && npm test && npm run build`：退出码 0；lint、格式通过，15 个文件/58 项单元测试通过，TypeScript 与 Vite 生产构建通过。`git diff --check` 通过。首轮发现新增单调时钟初始化的 receiver 问题，修正为闭包后上述最终检查全部通过。
- 本轮未执行 Playwright 或浏览器视觉验收，由主 Agent 在可启动浏览器的环境补跑；不沿用此前浏览器结果宣称本次返工已通过浏览器验收。
