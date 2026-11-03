# 实例业务日与首页 Key 请求汇总

评审已批准以下简化设计。先交付业务日，再独立提交首页面板。环境是唯一设置来源，无 schema 变化。

## 依据与范围

依据 [U10—U14](../../reference/specs/usage.md)、[管理契约](../../reference/specs/control-plane.md)、[O16](../../reference/specs/operations.md) 和[职责](../../architecture/ownership.md)。持久时间仍为 UTC Unix 秒；滚动 24 小时、提供者窗口、保留时长及 Key 到期的 UTC 日期契约不变。仅本机合成验证，不访问真实订阅或部署。

## 一、业务日

Core 增加 `BusinessDayDefinition(offsetMinutes:)`，纯值类型，以 floor division 与溢出检查计算 start(t)=floor((t+o)/86400)×86400−o、end=start+86400，左闭右开。

`CODEXONE_BUSINESS_DAY_OFFSET` 严格接受 `UTC` 或 `±HH:00`，−12:00 至 +14:00，缺省 UTC，零偏移规范化为 UTC。非法设置沿现有配置失败路径退出；启动记录规范化值。半小时时区与 DST 不支持。入口把同一定义传给 gateway、priming、store/reader、管理 API 与恢复维护；不分散读取环境。重启修改立即生效，无定义历史、应用命令、匹配门禁或补偿。

Adapters 只有一个 Swift helper 生成日开始 SQL 表达式，offset 使用绑定参数；范围上下界由 Core 计算后绑定。查询范围内时间非负，整数除法仅封装在该 helper。通用小时查询保持 UTC 整小时网格。

### 完整依赖清单

| 层/文件与锚点 | 决定与理由 |
| --- | --- |
| `Sources/CodexOneCore/Domain/Time/WallClock.swift`：utcDay | 改：移除生产业务调用，迁往 BusinessDayDefinition；Unix 秒/微秒和单调耗时保持。无剩余调用时删除 utcDay，避免两个业务日来源。 |
| `Sources/CodexOneCore/Application/Execution/SingleIdentityGateway.swift`：execute；`AccountPoolGateway.swift`：execute | 改：不再构造 utc-day 字符串；传候选业务日窗口，在原子准入最终定时。涵盖托管 Key、静态单身份、账号池及 generation/warmup/compact。 |
| `Sources/CodexOneCore/Application/Execution/ExecutionCoordinator.swift`：execute；`ExecutionStore.swift`：admit | 改：返回并使用事务最终确定的 admission，不能把准备时的旧窗口留在 ExecutionContext；ticket 在 intent 前取得，提交后无新的可抛准备步骤。 |
| `Sources/CodexOneCore/Application/Usage/UsageQueries.swift`：UsageQuery | 改：保留 UTC 整小时网格（整小时偏移已对齐）；31×86400 时长上限、100 行和数值范围保持，详见 API。 |
| `Sources/CodexOneCore/Application/Execution/SnapshotMaintenance.swift`：RestoreRecord 最小冻结/首次核对 | 改：恢复日与首次核对日使用业务日末；继承较长冻结、CAS、全时间未知责任不变。 |
| `Sources/CodexOneCore/Application/Execution/ExecutionStore.swift`：ExecutionLimits | 保持：30 天绑定、90 天明细、24 小时核对是经过秒数，不是日历日。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteKeyGovernance.swift`：keyTokenUsage/checkKeyAdmission | 改：以事务内同一 now 的业务日区间累加；Token 口径和并发限制保持。不能只改摘要。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteExecutionStore.swift`：recordUnexpectedExecution/admitTransaction/insertAttempt | 改：异常执行也使用统一定义；恢复库窗口校验移除 utc-day 假设。created_at、window_id、admission_json 使用同一事务时间与定义；旧窗口不改写。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteAccountRouting.swift`：admitTransaction 调用 | 改：账号选择与 Key 限额检查仍在原事务，传同一准入时刻，不让等待跨午夜产生陈旧窗口。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteExecutionMaintenance.swift`：rollUp | 保持：UTC 日 rollUp、汇总/删 evidence/删 attempt 同事务。未知关闭、绑定到期、account_concurrency 清理及批量上限保持时长语义。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteConnection.swift`：governanceSchema/governanceColumns、版本/列门禁、只读 init | 保持：schema v11、列、索引与版本门禁；连接只传不可变业务日定义。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteUsageReader.swift`：keyUsage/dailyUsage | 改：今日/默认日范围/end 校验统一定义；options 的 ID 收集和全时间 last_used 保持。查询预算保持。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteUsageQueries.swift`：daily | 改：attempts 精确按业务日分桶；UTC 汇总日期 D 计入当地日期 D。 |
| 同文件 query/predicate | 保持 UTC 小时分桶；保持滚动查询、诊断 30 天淘汰、全时间治理与无精确时间的历史单列。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteGovernanceReader.swift`：headroom | 改 daily_requests/daily_estimated_micros；保持 peak24Hours 最近 86400 秒与 detail_rows。 |
| `Sources/CodexOneAdapters/Upstream/SubscriptionWindowPriming.swift`：executePriming | 改本地 admission 的 utc-day 标识；保持提供者窗口、内部 principal 和不占客户端 Key 限额。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteSnapshotMaintenance.swift`：backup/restore/reconcile/verifyBackup；`SQLiteConnection.swift`：restoreRecord | 保持 schema/restore JSON；恢复与首次核对传定义计算冻结截止；保留 .restore-pending、空目标、权限失效、审计与密钥依赖。 |
| `Sources/CodexOneAdapters/ControlPlane/UsageAdminAPI.swift`：daily/options/keys/document/parse/headroom | 改 timezone 元数据、日端点/end、通用 UTC 小时区间校验；计数/十进制字符串/认证/no-store 保持。 |
| `Sources/CodexOneRuntime/RuntimeConfiguration.swift`；`Sources/CodexOne/CodexOneMain.swift` | 改解析、错误、帮助/check-config、组装；启动记录规范化 offset，重启直接采用环境值。 |
| `Sources/CodexOneRuntime/ExecutionMaintenanceSupervisor.swift`、`OnlineBackupSupervisor.swift`、`AccountObservationSupervisor.swift` | 保持：60 秒维护轮次、每轮结束后 86400 秒备份间隔及 refreshWindowSeconds 是时长；不引入午夜定时任务。定义通过受监督的 store 使用。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteAttentionReader.swift`：keys/capacity | 改间接依赖：Key Token 提醒与 headroom 使用同一业务日/同一 now；保持 executions 滑动异常对比基线与最近自动重置卡的时长定义。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteExecutionDiagnostics.swift`；`SQLiteExecutionStore.swift` 诊断清理 | 保持：30 天诊断保留以 now 减时长定义。 |
| `Sources/CodexOneAdapters/ControlPlane/AttentionAdminAPI.swift`：keyExpirationSeconds | 保持：七天临期阈值不要求日对齐。 |
| `web/src/features/usage/api.ts`：parseUsage/defaults/usageParameters/日响应校验 | 改 timezone literal、业务日期映射及日边界校验；31 日/744 桶/严格日期/BigInt 保持；24h 保留 UTC 完成小时。 |
| `web/src/features/usage/UsageOverview.tsx`、`UsagePage.tsx`、`UsageSummary.tsx` | 改默认日期、快捷范围、日期标签、URL 日期解释、历史归档说明；上下端包含日期映射为业务日左闭右开区间。 |
| `web/src/features/usage/UsageTrend.tsx`、`format.ts` | 改日重分桶和日/小时趋势标签，显示实例 offset；UTC 精确时间格式函数保留用于详情。 |
| `web/src/features/system-status/round2-api.ts`、`ActivityOverview.tsx`、`OverviewStats.tsx`、`KeyResults.tsx` | 改 literal/边界校验、UTC 今日文案、趋势及面板元数据消费；不能 fetch 后丢掉窗口定义只返回 keys/buckets。 |
| `web/src/features/key-management/KeyLimitsSummary.tsx`、`KeyManagement.tsx`；`web/src/shared/presentation.ts` 每日请求标签 | 改 UTC 日限额/今日标签；相对时间和详情 UTC 瞬间提示保留。 |
| `web/src/features/key-management/KeyEditor.tsx`、`ExpirationEditor.tsx`、`date-input.ts`；`web/src/shared/date-input.ts` | 保持到期的独立 UTC 日期契约与校验；日限额改变不自动改变或延长 expiresAt。继续显式写“到期日期（UTC）”，日期未改保存原时刻。修改其契约另提案，避免权限变化。 |
| `web/src/shared/ui/TimeText.tsx`、`shared/presentation.ts` localTime；`web/src/features/account-management/AccountObservability.tsx`、`AccountManagement.tsx`；`system-status/AdminOverview.tsx` 配额时长 | 保持一般瞬间本地/UTC提示及提供者时长，不是统计日；新增面板“最近活动”和趋势显式用实例 offset formatter。 |


### 汇总、切换、窗口与恢复

`usage_daily` 保持 UTC 日，`rollUp` 完全不变；它仅汇总 90 天前已淘汰明细的 attempts，当前生产尚无这些行。UTC 日期 D 的汇总计入当地日期 D：当地范围 [S,E)、偏移 o，读取 day_epoch∈[S+o,E+o)。总量保留，超过 90 天的数据日界近似。此限制在用量页既有旧汇总说明中提示，不增加历史分栏或分页。所有 usage_daily 读取必须按清单复核；全时间 ID/lastUsed 不变。keyTokenUsage 还保守纳入覆盖业务日开始瞬间的 UTC 汇总行，避免低估。改 offset 不需数据工作。

当前限额从 attempts 按新边界重算，无补偿；已准入执行不迁窗、不释放责任。新 ID 为 `business-day-<startUnixSeconds>`，UTC 也使用此形式；旧 `utc-day-*` 保持可读。尝试以小改动在 admission 事务内设最终窗口，并将最终 admission 返回 coordinator/context；若不能小改必须记录决定。恢复库比较接受旧、新形式。

恢复冻结按恢复日及首次核对日的业务日结束计算，仍只存 UTC 截止，不存定义；继承截止永不缩短。CAS、intent/unknown 与恢复凭证屏障不变。

### API 与 web

options、daily、keys 和返回窗口的响应增加 `businessDay: {offsetMinutes}`，保留 timezone（`UTC` 或 `UTC+08:00`）。daily end 必须对齐业务日；通用 usage 仍用 UTC 小时网格，整小时 offset 已自然对齐。默认 UTC 除新增字段外保留行为和响应。

UI 先取服务端设置，再按该值构建今日、日期筛选、趋势与首页；不使用浏览器时区解释业务日期。日期转瞬间为 UTC(date)−o，结束日再加一天。Key 到期保持明确 UTC 输入及原 expiresAt。无 revision/409、第二小时网格或桶 origin。

### 回退

schema 仍 v11，无迁移，换回上一版本镜像可直接使用原库。回退后限额与统计恢复 UTC 日，新 attempts 中业务日窗口字符串不再参与旧版当前 UTC 窗口计数；历史执行仍应可读和结算。用合成库核查旧版对 business-day-* 的实际行为并记录；不承诺未测旧版。已有恢复冻结 UTC 截止继续保留。

## 二、首页“今日 Key 请求汇总”

### 当前字段、缺口与计量

`UsageAdminAPI.register` 的 `/api/usage/keys` 已返回顶层 start/end/timezone；每 Key 为 keyID、displayName、principal、enabled、admitted、succeeded、failed、cancelled、inFlight、pending、tokens（十进制字符串）、tokenUsageIncomplete、estimatedMicros（可空字符串）、lastUsedAtUnixSeconds（可空、全时间最近准入）。Core 类型为 `KeyUsageSummary`，读取为 `SQLiteUsageReader.keyUsage`。目前首页 `round2-api.ts` 的 schema 丢弃 tokens/完整度/费用/lastUsed 及顶层元数据，`KeyResults.tsx` 按请求量排序，默认活跃并可切“全部”。不能据此认定后端缺少 Token 或最近时间。

新增后端每 Key `inputTokens`、`cachedTokens`（可空十进制字符串）及 `cacheUsageIncomplete`。同一日区间、同一只读快照聚合。只在有已观测宿主用量的请求间累加 input/cached；失败或取消而无用量的请求不进入分母，tooltip 说明存在未观测用量的请求。现有 lastUsed 在今日有准入的行必然也是今日最后准入，故无需新增另一个“最后活动”字段；它不代表最后完成时间。pending 不等于结果未明，保留接口但不用于显示结果未知。

Token 直接消费现有 tokens/tokenUsageIncomplete；保证与 Key 限额共用 `SQLiteKeyGovernance.keyTokenUsage` 的计量投影和同一个日区间：普通/预热/压缩为 input（含缓存）+output；缓存不重复加；原生 Images 为 imageInput+imageOutput；图片工具 token 不额外加到宿主 token。缺失/部分证据显示“≥ 已观测”与说明；无请求的行不展示，存在请求但全缺证据也不把 0 当可信完整消耗。不能用 `round2-api.tokenTotal` 的宿主 input+output 替代治理 tokens，后者无法覆盖原生 Images。后续优化聚合时先抽取同一计量 SQL 投影供 writer 与 reader 使用，避免为面板另造公式。依据：`SQLiteKeyGovernance.keyTokenUsage`、`SQLiteUsageQueries.metrics`、U12。

缓存命中率 = 今日 SUM(cachedTokens)/SUM(inputTokens)，以累计 token 加权，不平均逐请求百分比。仅没有已观测输入（包括输入合计为 0）显示“—”；有完整输入且 cached=0 时 0% 是真实零命中，必须允许。需求中的“无用量时绝不 0%”不能解释为禁止真实 0%。分子不得大于分母；异常响应当无效数据处理，不钳成 100%。大整数先用 BigInt 安全求比、最后格式化显示，不能直接 Number 丢失精度。

### 行、排序、刷新与窄屏

- 仅首页使用 includeArchived=false，并过滤 admitted>0；启用/停用/到期不改变今日活跃定义，保留已停用状态。删除“今日活跃 / 全部”控件；零请求空态为“今日暂无活跃 Key”。Key 管理与历史 API 默认包含归档的语义保持。
- 六列依次为 Key、最近活动、请求、失败、Token、缓存命中率。失败形如 `39（25%）`，分母选 admitted，与面板请求数一致；取消/执行中/未明不计为失败，说明率是已准入请求中失败比例。没有准入前拒绝，失败不能用 pending 计算。
- 名称旁有非零“执行中 N”徽标；非零取消和结果未明在名称下的紧凑状态区显示，窄屏也不隐藏。结果未明仍为 admitted−succeeded−failed−cancelled−inFlight，保留非负一致性校验；它不等于待核对 unknown 或 token 缺证据。依据：现有 `KeyResults` 和 `round2-api` 校验。
- 名称优先 displayName，后备 principal；对于内部 `legacy-p-...` 后备名称改为“未命名 Key”，不在行内渲染该 ID。名称 hover/focus 提示及可点击详情显示完整 principal/keyID，移动端通过详情可达；重名依靠详情辨认。只改首页渲染模式，不全局改变 `shared/KeyName.tsx` 对其他页面的契约，也不改身份数据。
- 每次成功刷新按 lastUsedAtUnixSeconds 倒序，缺失置底，同秒按 keyID 稳定升序；复制数组排序，保持 React key=keyID。新请求可让行升到顶部，结算修订本身不改变顺序；不冻结旧排序、不动画交换。刷新时保留旧快照和更新时间，错误显示陈旧提示；日界到来时旧快照须标旧窗口，不能仍称今日。保留当前焦点/详情绑定 Key，避免刷新把点击目标换到另一 Key。
- 复用 `shared/ui/DataTable.tsx` 的响应式标签机制：大屏六列，窄屏每 Key 卡片式堆叠，首行名称/执行中/最近活动，随后请求与失败、Token 与缓存，非零取消/未明始终可见；名称可换行，精确数值可展开/提示，失败链接和详情均支持键盘与触摸。不得靠隐藏列或 hover 才能看异常。

高失败率采用保守的样本门槛规则：仅 admitted≥20、failed≥5 且 failed/admitted≥20% 时，用橙色强调失败单元格并标“失败偏高”；其余仍显示完整数率与链接，不警报整行。20/5/20% 是已批准的展示规则，未声称来自运营数据或统计显著性；tooltip 给出规则，小样本不变成醒目红色。阈值边界须有测试。

### 失败链接与诊断兼容

现有 `web/src/features/usage/UsagePage.tsx` 已读取 URL 的 key/start/end/failedOnly/state 等，`UsageOverview` 有“仅异常结果”，`UsageAdminAPI.parse` 支持相应查询，故 Key+今日范围可复用。但 `SQLiteUsageQueries.predicate` 的 failedOnly 对 admitted 使用“failure 非空”，diagnostic 不排除；它不等价 `outcome.kind='failed'`，且 state=settled 也不是失败状态，不能假称今天就支持精确面板失败过滤。

加可选 `outcome=failed` 到 UsageQuery、API 严格枚举、web filters/URL/表单和导航记忆。该条件仅筛选 admitted 且 outcome.kind=failed，排除准入前 diagnostics，优先定义为精确结果过滤；与 failedOnly 同时出现时按 AND，state 继续独立表示执行状态。现有 failedOnly 行为保持，用于更宽的异常排查。

非零失败数链接至 `/usage?key=<编码ID>&start=<业务日期>&end=<同日>&outcome=failed`（路由实际由当前 HashRouter 生成）。使用摘要返回的 start/end 与定义生成日期，不能点击时用浏览器今日重算。跨午夜仍打开行所属日期。零失败显示普通 `0（0%）`；若以后允许点击零值也必须有正确空态。新筛选应让详情总数等于面板该快照 failed，晚到结果或刷新时刻不同可使后续计数变化，要显示更新时间而非承诺跨请求原子快照。

每 Key 首要失败原因本次不做。以后可在同一有界读快照按 Key+failure 分类聚合，按次数与固定枚举稳定取首位，并带统计时间/缺失说明；daily.failures 已有分类聚合但不是逐 Key 摘要，不应为每行额外发 daily 查询。依据：`SQLiteUsageQueries.daily`、`UsageAdminAPI`。


## 交付与验收

不引入 schema、来源列、定义历史、SQLite 自定义函数或离线应用命令。失败链接仅携带摘要的起止日期、Key 和 outcome，不携带定义版本。测试覆盖事务跨午夜、限额在当地而非 UTC 零点重置、重启改偏移、UTC 汇总映射、偏移恢复冻结、非法设置、−12/+14 与默认 UTC；有进程边界处使用真实二进制和 fake provider。运行 web 单元测试和大/窄屏合成浏览器操作；完整后端验证只在最后运行一次，其间不 relink。

## 相关文档

[实施任务](tasks.md) · [用量规范](../../reference/specs/usage.md) · [管理规范](../../reference/specs/control-plane.md) · [运行规范](../../reference/specs/operations.md)
