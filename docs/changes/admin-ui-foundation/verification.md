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
