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

## 复核返工 · 2026-10-31

本轮仅当前 worktree、macOS arm64 与全新 Chrome 合成上下文；授权边界沿用上轮。未修改 STATUS，未访问其他 worktree/主 checkout、SSH、部署实例、真实订阅，未运行 Docker/Linux、push 或 PR。

新增浏览器回归位于 `web/tests/e2e/ui-review-rework.spec.ts`；下表使用实际测试标题前缀定位。

| 返工项 | 修复方式 | 回归测试名/前缀 |
|---|---|---|
| P2-1 | 收起更新后将展开按钮滚至视口中央并保留焦点 | `P2-1: collapsing fifty reminders` |
| P2-2 | Key 仅 POP 恢复，等待摘要与列表布局稳定且每个导航只定位一次；用量按筛选+页码分别存游标/窗口/位置，PUSH 新进入从顶部读取当前 query | `P2-2 Key: POP restores`、`P2-2 Usage: pages keep separate POP positions`；Vitest `P2-2 restores only the matching page snapshot on POP=%s` |
| P2-3 | 首次错误只留表格内一处与重试，已有快照失败才用外层横幅 | `P2-3: first Key failure has one error` |
| P2-4 | 用量首次失败无快照用语；成功后才显示快照时刻；概览七类来源合为一条横幅，区块首次失败不造空态 | `P2-4: first failure has no snapshot claim` |
| P2-5 | 分页旁提示失败目标页、原快照时刻及重试；不清原页，重试沿用失败游标与固定窗口，仍可操作分页 | `P2-5: 503 page failure`、`P2-5: 429 page failure` |
| P2-6 | 登录自动聚焦凭证；取消/Esc 回到创建按钮或菜单触发按钮；Key 目标行可聚焦且有名称 | `P2-6: login, Key targets and cancel/Escape` |
| 颜色语义 | 到期 Key 列表开关及一次性凭证的纯开关标签中性；非状态折叠入口/说明使用主色；有授权异常的账号状态点为警告色 | `Colors: expired switches are neutral`、`P2-6 Colors: rotating an expired Key` |
| 额度卡链接 | 账号名称携带 target ID，复用提醒的账号详情机制 | `Quota: an account name opens that account's details` |

独立 subagent 源码复核：P0/P1 均为 0，发现三处 P2，均已修正并补回归：POP 慢速恢复失败/重试期间冻结原位置（Vitest `P2-2 P2-5 preserves POP scroll through a slow failed restore and retry`）；旧轮换框退场发现新凭证框时不抢焦点；一次性凭证框的开关标签改中性。轮换成功回归等待旧框实际卸载后检查焦点仍在新框。快速筛选的旧渲染不得提前消耗后续翻页定位；既有 `K01 K02 K05` 覆盖该路径，并在断言前等待已选筛选及翻页定位实际生效。

### 合成走查与截图

重跑 `artifacts/ui-review/after.mjs`、`after-usage.mjs`，以及 `review/overview2.mjs`、`keys.mjs`、`forms.mjs`、`usage.mjs`、`misc.mjs`、`misc2.mjs`、`hidden.mjs`。复核原图保留，新增图输出至忽略的 `artifacts/ui-review/after/rework-*.png`；走查 JSON/日志同样只留在忽略目录。

本轮新增 42 张复核/诊断 after PNG，另更新既有 35 张综合 after PNG。尺寸包括 1920×1080、1440×900、1280×800、390×844。直接查看收起后焦点、概览失败汇总、底部分页 429 与窄屏详情截图；观测：新进入 Key/用量的 scrollY 均为 0，用量第二页返回 1320→1320；分页 429 横幅 y≈783 且下一页可操作；菜单取消/Esc 返回对应按钮；隐藏目标重置后仍定位高亮。所有走查的外部阻断列表均为空，模拟 401/429/503 的控制台网络错误属于注入的失败。

### 最终命令结果

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---:|---:|---|
| `./scripts/verify.sh --web --chrome` | 0 | 63.60 秒 | lint、格式、类型、构建；Vitest 131 项、Chrome 32 项全通过 |
| `node artifacts/ui-review/after.mjs` | 0 | 35.92 秒 | 四种视口、19 项原走查、35 张综合 after，外部请求 0 |
| `node artifacts/ui-review/after-usage.mjs` | 0 | 8.50 秒 | 慢速第二页返回恢复 1320→1320 |
| `node artifacts/ui-review/review/overview2.mjs` | 0 | 15.01 秒 | 50 项提醒收起焦点、首次/旧快照失败汇总 |
| `node artifacts/ui-review/review/keys.mjs` | 0 | 15.32 秒 | Key 分页/筛选/返回、轮换 Esc 焦点、精确到期时刻 |
| `node artifacts/ui-review/review/forms.mjs` | 0 | 23.07 秒 | 首次 Key 429、登录焦点与 429、1920/1280 表头 |
| `node artifacts/ui-review/review/usage.mjs` | 0 | 33.05 秒 | 1440/1920 分页、详情 Esc 焦点、首次 503/429、翻页 429 |
| `node artifacts/ui-review/review/misc.mjs` | 0 | 11.32 秒 | 侧栏新进入 Key/用量均回顶，分页 429 原地反馈可重试 |
| `node artifacts/ui-review/review/misc2.mjs` | 0 | 5.94 秒 | 已有第二页记忆时新进入仍为第一页，scrollY=0 |
| `node artifacts/ui-review/review/hidden.mjs` | 0 | 4.88 秒 | 目标隐藏/重置后定位，取消返回原菜单按钮 |
| `python3 scripts/check_docs.py` | 0 | 0.06 秒 | 209 篇 Markdown 的链接、入口与变更结构通过 |

表内 `after.mjs`、`review/keys.mjs`、`review/misc.mjs` 为最终代码复验耗时；其余为本轮原脚本重跑。九种走查共执行十二次，全部退出 0，累计 232.95 秒。最终复验的综合脚本仍确认外部请求 0、表头 64 px、用量返回位置一致。

迭代说明：首轮完整入口退出 1（66.84 秒），Key 快速筛选/翻页时序及移动端流程未通过；随后修正翻页定位竞态与过时测试定位，移动端定向复验通过，最终完整入口结果以上表为准。早期源码/测试迭代日志保留在忽略目录，未将中途失败写成通过。

未修项：无。本轮新增 11 项 Chrome 回归及 3 项 Vitest 回归；既有用量慢速恢复/400 游标回退测试继续通过。仅前端合成验收，未执行后端、生产 CSP/live 或跨平台验证。提交前检查新增文件/差异未发现本机私有路径、外部私有地址、真实凭证或私钥；一次性凭证 fixture 均为合成值。

## 合并后回归定位与修复 · 2026-10-31

平台：macOS arm64、全新 Chrome 合成上下文。仅当前 worktree；未修改 STATUS，未 SSH/部署、调用真实账号或订阅、运行 Docker/Linux、push 或 PR。

### 根因与修复

- 两次 merge 未改动用量视图记忆、请求详情或相关 CSS。未修改代码时两项单次定向测试都曾通过，但两轮各 16 次诊断分别复现 5 次和 4 次失败；不能归因于新增备份提醒或断开结算。诊断脚本已移除，采样日志不进入仓库。
- POP 恢复曾调用 `scrollTo(0, 1800)`，但请求完成后的 `requestAnimationFrame` 不保证 React 并发渲染已提交，短加载页面将位置钳到 0。改为提交后的 `useLayoutEffect` 执行定位，同时核对读取 epoch 与对应 report，翻页仍滚动并聚焦请求明细。增强慢读取单测：模拟帧先于渲染，断言滚动时第二页和请求行已经存在；慢速失败/重试、失效游标回退等既有用例保留。
- 390×844 横向溢出源自背景趋势图：桌面悬停后 Recharts 隐藏 tooltip 保留旧 transform，盒子右沿约 979.5 px，将 body 撑至 980 px；图例重算前也会暂留桌面宽度。趋势面板使用 `overflow-x: clip` 限制图表装饰边界，不裁剪整页或 Drawer，不引入额外纵向滚动。原 390 px 断言不变，新增先悬停图表再打开详情/缩窄的实际交互。
- `first` 重复 key 来源为 `admin-productization.spec.ts` 的合成接口：每页重复同一条 `id=first`，却始终声明 `nextCursor=synthetic_cursor`，首页最近请求聚合出十个重复行。修正该单页夹具为 `nextCursor: null`，增加最近请求恰好一行与无重复 key 控制台警告的断言，不改生产行标识来掩盖数据问题。
- 完整入口另暴露 Key 用例前提竞态：URL 已清空筛选，但旧“已到期”第一页也有 50 行，旧断言会提前放行并点击旧视图的分页。失败快照仍为“已到期”、第二页仅一行，table top=396.375。新增等待“全部”选中及准确“共 204 个”，保留原分页位置、吸顶与返回断言。

独立 subagent 只读源码 review：P0/P1/P2 均为 0。浏览器额外走查 1440×900、390×844：详情打开/关闭 body 均为 390 px；窄屏图例与重新悬停 tooltip 可见，tooltip 边界 x=108、宽约 210.67 px；慢速第二页 POP 恢复到 1800；外部请求与重复 key 均为 0。三张截图与走查脚本保存在忽略目录 `artifacts/ui-review/merge-regression/` 及其同级脚本中，已直接查看桌面/手机详情和窄屏图表。

### 命令记录

| 命令 | 退出码 | 耗时 | 关键结果 |
|---|---:|---:|---|
| `npx vitest run src/features/usage/UsageOverview.test.tsx`（web） | 0 | 1.57 秒（Vitest 报告） | 11 项通过，含提交后定位、慢速失败重试及失效游标 |
| `npx playwright test --project=chrome admin-productization.spec.ts ui-review-rework.spec.ts -g 'login overview\|P2-2 Usage' --repeat-each=8 --workers=4`（web） | 0 | 30.69 秒 | 原两项各 8 次，共 16 次全部通过，无重复 key 警告 |
| `node artifacts/ui-review/merge-regression.mjs` | 0 | 4.56 秒 | 桌面/窄屏详情、图例与 tooltip、慢速 POP；外部请求 0 |
| `./scripts/verify.sh --web --chrome` | 0 | 71.98 秒 | lint、格式、类型、生产构建；28 个 Vitest 文件 134 项、Chrome 33 项全部通过；重复 key 警告 0 |
| `python3 scripts/check_docs.py` | 0 | 0.16 秒 | 215 篇 Markdown 的入口、本地链接与变更结构通过 |

迭代说明：一次早期完整入口与诊断运行重叠，共享 Playwright trace 目录产生 ENOENT，该次不作为产品验证结论；后续 E2E 入口独立执行。修复后的首次完整入口退出 1（58.84 秒），原两项通过，Key 用例前提失败；修正上述前提后再运行完整入口，最终 134 项 Vitest 与 33 项 Chrome 全通过，见上表。走查初次因图例/tooltip 同名定位不唯一退出 1，改为限定图例容器后通过，无产品代码变更。

仅前端本机合成验证；未运行后端、生产 CSP/live 或跨平台构建。

本轮提交前 `git diff --check`、新增差异敏感信息检查及 STATUS 未修改检查通过；无未知或未提交的产品工作。构建工具的 Vite native-config 预告、部分零尺寸图表预警及 jsdom scrollTo 提示仍属既有测试环境输出，不影响上述断言通过。
