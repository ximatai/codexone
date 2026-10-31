# 验证记录

2026-10-31 · macOS arm64 · Chrome 156 · 全部为当前 worktree 的合成 API。无 SSH、部署实例、真实账号/订阅/OpenAI、Docker/Linux、push 或 PR；STATUS 未修改。

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---:|---:|---|
| `./scripts/verify.sh --web --chrome` | 0 | 39.53 秒 | lint、格式、类型、构建；Vitest 126 项、Chrome 21 项通过 |
| `npm run lint && npm run format:check && npm run typecheck && npm run test:e2e:chrome` | 0 | 32.88 秒 | 合成网络边界补强后 Chrome 21 项通过，无默认端口代理连接 |
| `npm run lint && npm run format:check && npm run typecheck && npx vitest run src/features/usage/UsageOverview.test.tsx && npx playwright test --project=chrome ui-review-fixes.spec.ts -g "U02 U03"` | 0 | 7.68 秒 | 用量慢速恢复/400 游标回退补充后，Vitest 8 项及 Chrome 1 项通过 |
| `python3 scripts/check_docs.py` | 0 | 0.05 秒 | 209 篇 Markdown 的本地链接、入口与变更任务结构通过 |
| `node artifacts/ui-review/after-usage.mjs` | 0 | 3.48 秒 | 最终代码慢速返回走查通过，更新 U02/U03 截图，scrollY 1320→1320 |
| `node artifacts/ui-review/after.mjs` | 0 | 34.67 秒 | 1440×900、1920×1080、1280×800、390×844；35 张修复后截图；外部请求 0 |

入口结束后发现旧 E2E 的少量未覆盖读取会尝试默认 loopback 端口并被拒绝，未连接到服务。补统一 auto fixture：未显式模拟的管理 API 固定返回合成 404、外部来源直接阻断。变更后仅重验受影响的前端静态检查与 Chrome 入口，结果见上表。

## 清单与回归映射

浏览器回归均位于 `web/tests/e2e/ui-review-fixes.spec.ts`，标题以前缀清单号命名。

| 编号 | 修复 | 回归测试标题前缀 |
|---|---|---|
| O01 | 提醒携带 ID，Key 自动换页定位高亮，账号打开详情；缺失/筛选隐藏给提示 | O01 O03 |
| O02 | 请求卡独立失败/重试，成功空数组才显示无请求；指标失败也不造值 | O02 A03 K09 |
| O03 | 默认五条、严重度与对象类别计数、展开/收起；紧急项优先 | O01 O03 |
| A01 | 卡片与名称可收缩、安全换行，四种尺寸无横向溢出 | A01 A02 |
| A02 | 策略/授权独立标签，未知黄、重授权红 | A01 A02 |
| A03 | 首次失败不显示首个账号引导，旧快照标明读取时刻 | O02 A03 K09 |
| K01 | 共用桌面表头在 64 px 顶栏下吸顶，数据行保持普通布局；Key 每页 50 条 | K01 K02 K05 |
| K02 | 搜索/状态/页码进 query，返回恢复筛选与会话内滚动位置 | K01 K02 K05 |
| K03 | 轮换确认含共享 Key 名、主体、可选择复制的完整 ID、当前开关 | K03 K04 K06 |
| K04 | 摘要失败/缺条目显示不可用，读取中明确提示，不推断从未使用 | K03 K04 K06 |
| K05 | 按已定可用状态口径筛选，开关/有效期分列标签 | K01 K02 K05；`expiration.test.ts` 边界测试 |
| K06 | 展示真实 UTC 秒，未改日期保留原值，改日期预览旧值→新值 | K03 K04 K06；`ExpirationEditor.test.tsx` 原日期恢复保存 |
| K07 | 创建/编辑均允许过去时间，统一“保存后立即拒绝新请求”警告 | K07 K08 L01 L02；`ExpirationEditor.test.tsx` 过去时间保存 |
| K08 | 治理阈值按最多六位美元小数，编辑摘要/当前策略摘要均保真 | K07 K08 L01 L02 |
| K09 | 首次失败数量不可用，无 0 或未创建空态 | O02 A03 K09 |
| U02 | 翻页成功滚动并聚焦请求明细标题，避开顶栏 | U02 U03 |
| U03 | query 页码 + 会话内有界游标/固定窗口/位置，返回后恢复；失效提示回首页 | U02 U03 |
| L01 | 匿名首页明确管理员登录入口，保留公开运行状态 | K07 K08 L01 L02 |
| L02 | 登录 429 提示繁忙与手动等待重试，提交凭证清空 | K07 K08 L01 L02 |

额外回归：`view-memory.test.tsx` 检查 32 项容量、非法页码与跨路由会话失效清理；已有账号 401/迟到授权、Key 部分失败、用量固定窗口/429 旧快照等测试继续通过；`UsageOverview.test.tsx` 新增慢速恢复中布局滚动不覆盖保存位置、400 游标拒绝明确回退。

## 界面复核与边界

修复后脚本复用原走查 harness，在 context 层拦截全部 API 并阻断外部来源。截图/脚本/观测 JSON 留在被忽略的 `artifacts/ui-review/after/`；35 张 PNG 与 `checks.json`：Key 表头 top=64、数据单元格 position=static；非零点到期保存前后 Unix 秒相同；用量翻页标题 y≈80；第二页返回 scrollY 1320→1320；blocked=[]。主执行者检查账号长名、50 条提醒、表头、失败态及窄屏截图。

独立 subagent 源码 review：P0 0；发现表头规则误覆盖 td（P1）、会话清理闭包与无界恢复记录（P2），均已修复；页码统一正整数校验并参数化测试。Key 翻页改为更新后滚动/聚焦，避免旧行布局与焦点影响落点。

未修项：无。无后端 API/schema/准入语义变更。用量游标不进入 query，只记录页码并在会话内存保留游标，符合已定界面安全边界；刷新整页后没有游标会明确退回第一页。仅本机开发 SPA 合成验收；本次未运行生产网关 CSP/live 脚本、后端或跨平台构建，未扩张为真实链路验收。
