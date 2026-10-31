# 管理台基础层阶段 1 验证

日期：2026-10-31；平台：macOS arm64，本机 Chrome，全新合成会话。没有访问部署实例、真实订阅或 OpenAI 端点，没有 Docker/Linux 构建、push 或 PR。

## 实现与范围

- `app/theme.ts` 集中主题；Vite 配置插件在 dev/build 启动时调用 Mantine 官方变量 resolver，生成忽略的 `app/generated/theme.css`，以普通 CSS import 打包。生成目录不入库，也不作为格式检查输入；单元测试断言主色及浅/深色 scheme。深色开关不开放。
- 提取 WorkspaceFrame 和 PageHeader；保留导航、路由和可访问名称。新增 `@mantine/notifications` 精确版本 9.7.3，传递依赖含同版本 `@mantine/store`；未引入其他 UI 库。
- Key 修改使用 useManagedMutation；会话 owner、CSRF、同源/超时边界不变，409 刷新不重放，未确认结果锁跨页面保留；400/413 保留草稿。一次性凭证只在 feature 局部持有，mutation 返回 void；真实创建 mock 路径断言 Query/Mutation state 不含 secret。
- DataTable、状态/空态/错误、时间/金额及统一确认框提供基础展示。MoneyText 被 KeyList 与既有 KeyLimitsSummary 使用；StatusBadge 被列表和秘密确认视图使用；ConfirmModal 被禁用和轮换使用。DataTable、PageHeader、TimeText 本阶段仅在 Key 试点使用：阶段 1 明确禁止迁移其他三个页面，因此不为满足复用数量越界改页；EmptyState/ErrorState 由通用表格状态复用，ErrorState 另用于 Key 读取失败。阶段 2 再接入其他页面，不预建 StatCard/图表等本阶段没有消费者的组件。
- Mantine 默认滚动条补偿依赖 react-remove-scroll-bar 动态 style，不能在现有 CSP 下使用。Key 弹层保留 Mantine 焦点、滚轮/触摸隔离，设置 removeScrollBar=false，使用静态 body:has 规则隐藏背景滚动。Key 不再维护 management-overlay-open；其他页面原逻辑保留，后端 CSP 未修改。

## 实际命令

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---:|---:|---|
| `cd web && npx vitest run src/shared/ui/ui.test.tsx src/shared/useManagedMutation.test.tsx src/features/key-management` | 0 | 1.67 秒 | 6 files / 25 tests passed（之后另增草稿回归测试，纳入完整入口） |
| 基线临时副本运行 `UI_FOUNDATION_SNAPSHOTS=before` 的 Key foundation Playwright 场景 | 0 | 9.2 秒 | 1440×900、390×844，2 passed |
| `cd web && UI_FOUNDATION_SNAPSHOTS=after npx playwright test ui-foundation --project=chrome` | 0 | 9.1 秒 | 2 passed，8 张稳定状态截图 |
| `./scripts/verify.sh --web --chrome` | 0 | 20.2 秒 | lint/format/typecheck、Vitest 82、生产构建、Chrome 8 项 |
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 swift build --product codexone` | 0 | 67.6 秒 | Build complete（Swift 报告编译 58.69 秒） |
| `python3 scripts/verify_admin_ui.py --binary .build/debug/codexone` | 0 | 8.7 秒 | PASS: real Chrome login, create/copy/clear, effective policy/CAS, disabled rotation/quota, read retry, lost mutation response and logout retry; no persistent browser secrets |
| `python3 scripts/check_docs.py` | 0 | 0.06 秒 | PASS: 186 Markdown documents |

完整 Vitest 包含 mutation 成功/失效通知、409 不重试、401、网络失败未知锁、卸载/代际退休取消；DataTable 排序和空/加载/错误/窄屏标签；TimeText local/utc/relative/null；主题两套变量。Playwright 检查可访问交互、手机无横向溢出与静态滚动锁。真实后端生产路径额外打开到期/禁用弹层，断言 body overflow=hidden、style 标签数为零，console 无 CSP 违规，覆盖实际严格 CSP。

迭代中修正：生成目录导致首次格式入口失败，已排除；旧“全页唯一 alert”断言与通知/退出动画短暂共存冲突，修改反馈改定位通知，读取/登出提示按文本限定。冲突刷新失败只显示一次修改错误，成功通知使用 status。入口失败后已修复并重新验证。没有把 Vite dev 无 CSP 的结果代替生产 CSP 验收。

构建非阻塞告警：现有部分 E2E 的未拦截合成读取产生本机代理拒绝、既有首页 fixture 重复 first key；生产 chunk 大小告警；SwiftPM 本机镜像存在依赖 identity 告警。没有扩大到部署或真实数据。

KeyManagement.tsx：584 → 287 行；useKeys.ts：233 → 197 行。原 78 行手写修改状态机替换为 41 行 feature 适配（共享 hook 单独承载跨页面约定），移除 12 行 Key 手写滚动锁；列表/到期编辑拆分属于移动，不计作净删代码。

## 截图与评审

截图在忽略目录 `artifacts/ui-foundation/{before,after}/`：各有 1440 与 390 的 list/edit/expiration/disable，共 16 张。before 来自当前分支起点的 git archive 临时副本（位于本 worktree 的 artifacts，结束后移除）；没有 stash、修改其他 worktree。捕获等待 350ms 使 Mantine 分帧过渡稳定，再禁用动画截图。

有意变化：主题 resolver 统一按钮/徽章绿色；可排序主体表头；窄屏显式标签替代 data-label 伪元素；列表行和标签间距小幅统一；修改反馈进入通知。导航、业务字段、限制、权限和弹层文案不变，窄屏抽屉宽度可操作。

subagent 只读评审提出两项 P2（校验失败草稿与 secret 测试强度），已修复并复核；截图动画捕获问题已重生成，subagent 最终复核 16 张均完整、无裁切或布局退化，无剩余评审阻塞。主 Agent 最终评审与 Linux verification 不属于本执行者完成项，任务末项保持未勾选。

## 阶段 2：页面迁移

日期：2026-10-31；平台：macOS arm64、本机 Chrome、新建合成会话。只修改本 worktree；未访问部署实例、真实订阅/OpenAI 端点，未运行 Docker/Linux、push 或 PR。

完成浅色侧栏、当前路由高亮、顶部退出与窄屏 Burger/导航 Drawer；主题保持 8px 圆角、细边框、无阴影及深绿，仍生成两套静态变量但不开放深色切换。依赖精确固定 `@mantine/charts 9.7.3`、`recharts 3.9.0`、`@tabler/icons-react 3.35.0`，锁文件同步。

概览 KPI 使用 AreaChart，缺失值保持 null 与可访问趋势文本；请求 DataTable、订阅额度/系统侧栏保留自动刷新、暂停、更新时间与 overview 查询分组。用量保留 URL/游标窗口与全部统计证据，常用筛选加更多筛选、六项汇总、堆叠柱状图、键盘/行点击详情和 CopyButton。账号改卡片/详情 Drawer、SegmentedControl，共享 mutation 保留 409 刷新但不重放、401、未知结果锁与授权失效分类。Key 工具栏增加七天内即将到期筛选，图标操作/菜单保留确认和一次性凭证的局部持有、五分钟清除及不入缓存/通知行为。

所有弹层禁用动态滚动条补偿，仅打开时设置静态滚动标记，删除手写锁类全部残留。EmptyState/ErrorState/Skeleton 通过共享组件及表格在四页复用；旧全局 feature 样式清除。

### 命令与证据

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---:|---:|---|
| Key/共享层定向 Vitest | 0 | 1.92 秒 | 7 files / 29 tests passed |
| 账号定向 Vitest | 0 | 1.36 秒 | 4 files / 26 tests passed |
| 概览定向 Vitest | 0 | 1.68 秒 | 5 files / 18 tests passed |
| 用量定向 Vitest | 0 | 1.18 秒 | 2 files / 9 tests passed |
| `./scripts/verify.sh --web --chrome` | 0 | 21.72 秒 | lint/format/typecheck、Vitest 86、生产构建、Chrome 12 passed |
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 swift build --product codexone --disable-sandbox -j 12 --skip-update` | 0 | 73.03 秒 | Build complete（编译 35.30 秒） |
| 同环境 `swift build --product ExecutionProbe --disable-sandbox -j 12 --skip-update` | 0 | 9.42 秒 | Build complete |
| `python3 scripts/verify_admin_ui.py --binary .build/debug/codexone` | 0 | 10.75 秒 | real Chrome login/create/copy/CAS/rotation/quota/lost response/logout passed |
| `python3 scripts/verify_account_admin_ui.py --binary .build/debug/ExecutionProbe` | 0 | 13.49 秒 | OAuth/PKCE、CAS、未知结果锁、重新授权、额度失败保留/陈旧/恢复 passed |
| `cd web && npx playwright test accounts-phase2 --project=chrome`（仅截图过渡等待调整后） | 0 | 8.8 秒 | 1 passed，更新三张稳定截图 |
| `python3 scripts/check_docs.py` | 0 | 0.05 秒 | PASS: 189 Markdown documents |

账号脚本需要 test-only 运行时组装，使用既有 ExecutionProbe 产品而非正式 codexone。正式产品另已构建。首次 Swift 构建的公开 GitHub 拉取停滞，终止后验证本机已有缓存包含 Package.resolved 的全部锁定提交，复制到本 worktree 忽略的本地镜像，再禁用更新完成构建；未改变 Package.resolved、后端或公开配置。原始本机路径不进入提交。

Chrome 新增四个阶段 2 场景：用量筛选/分页与详情字段、账号 Drawer 内409与显式重试成功、Key 菜单/即将到期筛选、手机导航 Drawer。原有八个场景保留行为覆盖，仅适配 SegmentedControl/Drawer/通知结构。生产巡检扩展至概览图表、用量堆叠图与详情 Drawer；账号脚本保留全部合成失败流程并校验零 style 标签。两入口均监听 pageerror/CSP 拒绝，全部通过；后端 CSP 未改。

迭代修正：SegmentedControl 的 Playwright 操作改点击可见标签；关闭 Drawer 空 root 不再保留滚动锁标记；所有响应式 Grid 改静态 CSS；保留账号授权失效专用提示。一次误并发完整入口造成 Playwright trace 文件清理冲突，已改串行单次复验通过；之后收敛用量统计条，再次运行完整入口通过。生产 chunk 大小、Vite 配置未来加载方式提示、原合成 fixture 重复行 key/未拦截本机读取告警不影响通过，不将这些告警作为真实上游证据。

### 截图、差异与评审

忽略目录 `artifacts/ui-phase2/` 共 13 张：四页各 1440×900 与 390×844；另有概览请求详情、用量详情、账号详情、Key 菜单及创建 Drawer。截图仅合成数据；已逐张检查尺寸与桌面/手机布局。账号通知额外等待过渡稳定后更新截图。

与渲染图的主要差异及原因：

- AppShell 9.7.3 无条件渲染 InlineStyles；采用等价静态侧栏布局配 Mantine Burger/Drawer，满足严格 CSP。不是更改 CSP 或替换库内部实现。
- 不展示密钥前缀；概览使用主体名。账号凭证到期 null 显示不可用，不编造套餐、健康或时间。
- 保留完整统计、待核对占用、拒绝诊断和陈旧语义；用量六项汇总后直接展示趋势，其余统计折叠、治理证据在下方。详情仅展示已有字段，不虚构结束时间或推理 Token。
- Key 创建沿用真实 API 表单和模型/图片权限、独立限额展开；到期仍经既有独立操作设置，不将渲染图未支持字段写入创建请求。
- 多账号额度逐账号列出；公共连接/运行状态继续可见。小屏卡片纵排并保留全部字段与可访问操作。

subagent 检查了代码和桌面/手机截图，无剩余 P0/P1；提出的 P2（链接主色、页头间距/数值字号、账号共享错误组件、截图尺寸/动画）已修正。主 Agent 最终评审与 Linux verification 留给主 Agent，不据本机合成通过宣称真实订阅或部署验收。

行数（起点 → 本次）：styles.css 723→55；AdminOverview 252→263、ActivityOverview 361→286、SystemOverview 76→77；UsagePage 46→47、UsageOverview 774→492、UsageDetail 131→142；AccountManagement 587→564、useAccounts 270→237；KeyManagement 288→303、KeyList 215→239。图表/表格内容拆到 feature 内部组件，移动代码不计作净删；账号/Key 保留完整能力，不为压低单文件行数删除业务字段。
