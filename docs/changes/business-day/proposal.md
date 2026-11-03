# 实例业务日与首页 Key 请求汇总（待维护者评审）

本次只交付设计，不改变运行行为。维护者评审后才能实施；下文“拟”与接口、schema、阈值均为提议，不是已交付能力。业务日先落地，面板在其上独立交付。[任务](tasks.md)列出顺序与验收。

## 依据、范围与已定方向

已读根 AGENTS、CONTRIBUTING、README、STATUS，以及 [U10—U14](../../reference/specs/usage.md)、[管理契约](../../reference/specs/control-plane.md)、[O02—O04/O16](../../reference/specs/operations.md)、[身份](../../reference/specs/identity.md)、[执行责任](../../reference/specs/execution-lifecycle.md)、[层次职责](../../architecture/ownership.md)。当前代码基线为 schema v11，见 `Sources/CodexOneAdapters/Persistence/SQLiteConnection.swift` 的版本门禁与 `governanceSchema`。引用均为仓库相对文件名及符号，不引用部署记录。

维护者已决定：每日统计、Key 每日限额、管理 API 和 UI 共用一个实例业务日；固定 UTC offset、缺省 UTC；不实现 DST。所有持久时间戳仍是 Unix UTC 秒。滚动“最近 24 小时”、订阅账号配额窗口不改变。首页只显示今日有准入的未归档 Key，按最近活动倒序，移除范围切换，采用指定六列。没有真实账号、上游调用或部署验证；性能数字须由后续合成大库实测，不能从本设计推断。

现有 UTC 规则直接写在 U10/U12/U14、控制面 API/首页/Key 到期和 O16 恢复冻结中。实施时更新这些规范及配置、升级、快照维护指南；本次不把尚未批准的设计写成当前能力。

## 一、业务日

### 单一函数、设置与所有权

拟在 Core `Domain/Time` 增加纯值 `BusinessDayDefinition(offsetMinutes:)`，不依赖 SQL、Vapor、NIO 或系统时区；保持 `WallClock` 只负责读时钟。函数为 `start(containing:)`、`end(containing:)`、`isBoundary(_:)` 和生成窗口标识。唯一数学定义：令 o=offsetMinutes×60，D=86400，start(t)=floor((t+o)/D)×D−o，end=start+D，窗口左闭右开。使用真正向下取整及溢出检查，不能照抄 `WallClock.utcDay` 对负时间向零截断的实现。公开查询仍维持当前非负 Unix 秒范围。

拟设置 `CODEXONE_BUSINESS_DAY_OFFSET`，语法严格为 `UTC` 或 `±HH:MM`；`+00:00`/`-00:00` 规范化为 UTC。拟支持整分钟、范围 −12:00 至 +14:00（本提案的产品边界），包括 +05:30、+05:45；拒绝秒、空串、空白、无符号、越界和 IANA 名称。未设置为 UTC；非法值在 `RuntimeConfiguration.init(environment:)` 解析时报专用配置错误，入口沿现有错误模式退出 78、不开 listener、不回显原值。`--check-config` 显示规范化 offset；它只检查语法，数据库匹配由持锁启动/维护命令核对，不能谎称已应用设置。依据：`Sources/CodexOneRuntime/RuntimeConfiguration.swift`、`Sources/CodexOne/CodexOneMain.swift`。

入口把同一不可变定义传给 gateway、priming、store/reader、管理 API 和维护命令；不要各层重新读环境。现有 clock 传递位置见 `CodexOneMain.run`、`SQLiteExecutionStore.open`、`SQLiteUsageReader.open`、`SubscriptionWindowPriming`。数据库持久记录当前定义及 revision/生效 UTC 秒；配置与库不一致时普通启动拒绝服务，提示离线显式应用，不静默改限额。拟新增 `--apply-business-day` 离线命令，使用当前环境设置、同一实例锁，先备份再提交定义 revision 与审计。首次 v11→v12 迁移直接记录指定定义；以后包括改回 UTC 都走此命令，不提供在线写设置 API。

SQL 不复制 offset 算术：Adapters 在 writer、只读 reader 及维护连接注册确定性的 SQLite 标量函数 `business_day_start(epoch, offsetMinutes)`，回调唯一 Core 函数；offset 必须是显式参数，不从可变全局取值。日分组、归档和日边界校验使用该函数；准入与范围过滤由 Core 算出上下界、绑定 `created_at_epoch>=? AND created_at_epoch<?`，保留索引可用性。小时分桶单独由查询的 bucket origin 定义，不能用日函数替代时长计算。依据：`SQLiteUsageQueries.daily/query`、`SQLiteKeyGovernance.keyTokenUsage` 目前分别内嵌除法，而 `SQLiteUsageReader.read` 保持单 WAL 快照与取消预算。

### UTC/日依赖清单与处理决定

下表覆盖本次代码检索所得生产日边界、窗口字符串、日期输入、显示与相邻时长路径。文件从仓库根解析；符号是定位锚点。测试/fixture 随对应项改，不把所有 86400 都改为业务日。

| 层/文件与锚点 | 决定与理由 |
| --- | --- |
| `Sources/CodexOneCore/Domain/Time/WallClock.swift`：utcDay | 改：移除生产业务调用，迁往 BusinessDayDefinition；Unix 秒/微秒和单调耗时保持。无剩余调用时删除 utcDay，避免两个业务日来源。 |
| `Sources/CodexOneCore/Application/Execution/SingleIdentityGateway.swift`：execute；`AccountPoolGateway.swift`：execute | 改：不再构造 utc-day 字符串；传定义 revision 的候选窗口，在原子准入最终定时。涵盖托管 Key、静态单身份、账号池及 generation/warmup/compact。 |
| `Sources/CodexOneCore/Application/Execution/ExecutionCoordinator.swift`：execute；`ExecutionStore.swift`：admit | 改：返回并使用事务最终确定的 admission，不能把准备时的旧窗口留在 ExecutionContext；ticket 在 intent 前取得，提交后无新的可抛准备步骤。 |
| `Sources/CodexOneCore/Application/Usage/UsageQueries.swift`：UsageQuery | 改：原 UTC 整小时校验须兼容业务小时网格；31×86400 时长上限、100 行和数值范围保持，详见 API。 |
| `Sources/CodexOneCore/Application/Execution/SnapshotMaintenance.swift`：RestoreRecord 最小冻结/首次核对 | 改：恢复日与首次核对日使用业务日末；继承较长冻结、CAS、全时间未知责任不变。 |
| `Sources/CodexOneCore/Application/Execution/ExecutionStore.swift`：ExecutionLimits | 保持：30 天绑定、90 天明细、24 小时核对是经过秒数，不是日历日。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteKeyGovernance.swift`：keyTokenUsage/checkKeyAdmission | 改：以事务内同一 now 的业务日区间累加；Token 口径和并发限制保持。不能只改摘要。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteExecutionStore.swift`：recordUnexpectedExecution/admitTransaction/insertAttempt | 改：异常执行也使用统一定义；恢复库窗口校验移除 utc-day 假设。created_at、window_id、admission_json 使用同一事务时间与定义；旧窗口不改写。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteAccountRouting.swift`：admitTransaction 调用 | 改：账号选择与 Key 限额检查仍在原事务，传同一准入时刻，不让等待跨午夜产生陈旧窗口。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteExecutionMaintenance.swift`：rollUp | 改：归档按当前定义分组并持久保存边界来源；汇总/删 evidence/删 attempt 同事务。未知关闭、绑定到期、account_concurrency 清理及批量上限保持时长语义。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteConnection.swift`：governanceSchema/governanceColumns、版本/列门禁、只读 init | 改：v12、归档来源与定义 revision、所有连接的函数注册；索引与 PK 适配新列，不能沿用无列名 INSERT。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteUsageReader.swift`：keyUsage/dailyUsage | 改：今日/默认日范围/end 校验统一定义；options 的 ID 收集和全时间 last_used 保持。查询预算保持。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteUsageQueries.swift`：daily | 改：attempts 精确重分桶、归档按自身定义读取，禁止把 day_epoch 当精确准入时间再次分桶。 |
| 同文件 query/predicate | 改小时分桶 origin 以支持半小时日界；保持滚动查询、诊断 30 天淘汰、全时间治理与无精确时间的历史单列。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteGovernanceReader.swift`：headroom | 改 daily_requests/daily_estimated_micros；保持 peak24Hours 最近 86400 秒与 detail_rows。 |
| `Sources/CodexOneAdapters/Upstream/SubscriptionWindowPriming.swift`：executePriming | 改本地 admission 的 utc-day 标识；保持提供者窗口、内部 principal 和不占客户端 Key 限额。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteSnapshotMaintenance.swift`：backup/restore/reconcile/verifyBackup；`SQLiteConnection.swift`：restoreRecord | 改 schema 接受范围、旧 restore JSON 解码/验证、冻结定义及迁移设置；保留 .restore-pending、空目标、权限失效、审计与密钥依赖。 |
| `Sources/CodexOneAdapters/ControlPlane/UsageAdminAPI.swift`：daily/options/keys/document/parse/headroom | 改 timezone 元数据、日端点/end、通用区间校验和分桶 origin；计数/十进制字符串/认证/no-store 保持。 |
| `Sources/CodexOneRuntime/RuntimeConfiguration.swift`；`Sources/CodexOne/CodexOneMain.swift` | 改解析、错误、帮助/check-config、组装和离线命令；普通启动不隐式迁移。 |
| `Sources/CodexOneRuntime/ExecutionMaintenanceSupervisor.swift`、`OnlineBackupSupervisor.swift`、`AccountObservationSupervisor.swift` | 保持：60 秒维护轮次、每轮结束后 86400 秒备份间隔及 refreshWindowSeconds 是时长；不引入午夜定时任务。定义通过受监督的 store 使用。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteAttentionReader.swift`：keys/capacity | 改间接依赖：Key Token 提醒与 headroom 使用同一业务日/同一 now；保持 executions 滑动异常对比基线与最近自动重置卡的时长定义。 |
| `Sources/CodexOneAdapters/Persistence/SQLiteExecutionDiagnostics.swift`；`SQLiteExecutionStore.swift` 诊断清理 | 保持：30 天诊断保留以 now 减时长定义。 |
| `Sources/CodexOneAdapters/ControlPlane/AttentionAdminAPI.swift`：keyExpirationSeconds | 保持：七天临期阈值不要求日对齐。 |
| `web/src/features/usage/api.ts`：parseUsage/defaults/usageParameters/日响应校验 | 改 timezone literal、UTC 日期映射及网格校验；31 日/744 桶/严格日期/BigInt 保持；24h 保留 UTC 完成小时。 |
| `web/src/features/usage/UsageOverview.tsx`、`UsagePage.tsx`、`UsageSummary.tsx` | 改默认日期、快捷范围、日期标签、URL 日期解释、历史归档说明；上下端包含日期映射为业务日左闭右开区间。 |
| `web/src/features/usage/UsageTrend.tsx`、`format.ts` | 改日重分桶和日/小时趋势标签，显示实例 offset；UTC 精确时间格式函数保留用于详情。 |
| `web/src/features/system-status/round2-api.ts`、`ActivityOverview.tsx`、`OverviewStats.tsx`、`KeyResults.tsx` | 改 literal/边界校验、UTC 今日文案、趋势及面板元数据消费；不能 fetch 后丢掉窗口定义只返回 keys/buckets。 |
| `web/src/features/key-management/KeyLimitsSummary.tsx`、`KeyManagement.tsx`；`web/src/shared/presentation.ts` 每日请求标签 | 改 UTC 日限额/今日标签；相对时间和详情 UTC 瞬间提示保留。 |
| `web/src/features/key-management/KeyEditor.tsx`、`ExpirationEditor.tsx`、`date-input.ts`；`web/src/shared/date-input.ts` | 保持到期的独立 UTC 日期契约与校验；日限额改变不自动改变或延长 expiresAt。继续显式写“到期日期（UTC）”，日期未改保存原时刻。修改其契约另提案，避免权限变化。 |
| `web/src/shared/ui/TimeText.tsx`、`shared/presentation.ts` localTime；`web/src/features/account-management/AccountObservability.tsx`、`AccountManagement.tsx`；`system-status/AdminOverview.tsx` 配额时长 | 保持一般瞬间本地/UTC提示及提供者时长，不是统计日；新增面板“最近活动”和趋势显式用实例 offset formatter。 |

清单依据还包括 `SQLiteUsageQueries.query` 的 UTC 小时 SQL、`UsageTrend` 的前端 UTC 再分组、`SQLiteUsageReader.keyUsage` 的全时间 lastUsed，以及 `SQLiteAttentionReader` 的滚动基线；这些都不能只靠搜索 utcDay 找齐。

### API 与 web 兼容契约

拟在管理员 `GET /api/usage/options` 返回 `businessDay: {offsetMinutes, revision}`、`timezone`、`generatedAtUnixSeconds` 和当前业务日 start/end；`daily`、`keys`、通用 usage、headroom 同样携带此定义/窗口所需元数据。`timezone` 保留字段，UTC 时仍为 `UTC`，非零时为 `UTC+05:30` 形式；它是显示标识，算术以整数 offsetMinutes 为准，不交给浏览器解释成 IANA 时区。所有业务日标题/日期/小时标签均用此值。首屏先取得设置再生成默认筛选，不用浏览器时区猜测；失败显示不可用。缓存、游标历史、视图记忆按 revision 隔离，设置变更后清除旧范围并要求重新应用；请求可带可选 `businessDayRevision`，不匹配返回 409，避免打开旧页面时静默换日。

`GET /api/usage/daily` 的 days 仍为 1…31、默认 7、含今日；end 必须对齐当前业务日边界；`keys` 的窗口同一 start/end。通用 `GET /api/usage` 仍接受绝对 UTC 秒、最多 31×86400 秒，保留旧 UTC 整点客户端：start/end 必须同属 UTC 小时网格，或同属业务小时网格 `(t+o)%3600=0`，且相差整小时。不能独立放行两端不同网格。返回 `bucketOriginUnixSeconds=start`，小时桶用 `start+floor((t−start)/3600)×3600`，最多 744 个；SQL 由统一小时分桶 helper 生成，attempts 与 diagnostics 同口径。+05:30 的日历查询由此得到当地 00:00 起的 24 个小时桶，不丢掉半小时。滚动 24h 保持现有 UTC 已完成整小时 start/end 与取整方式，不改变覆盖时长；展示小时标签可为当地 xx:30，明确它是该桶开始时刻。

web 对 `timezone`/offset 的规范化对应关系、revision、左闭右开窗口、day/hour 网格、桶数量与连续性严格验证；替换 `api.ts`、`round2-api.ts` 的 `z.literal("UTC")`、`start%86400` 和全局 UTC 小时假设。日期输入仍严格验证公历日期，转换时 `UTC(date 00:00)−o`，含结束日时再加 D；快捷项及今日判断先把 now+o 映射成日期。趋势日聚合使用业务日函数，不再 Math.floor(epoch/86400)。

默认 UTC 的现有字段和时间范围语义保持；非零配置的旧 UI 会拒绝非 UTC timezone，是显式兼容破坏，须 API 与 bundled web 同版本升级。旧端点 `/daily?end=<UTC零点>` 在非零设置下可能 400，不能自动舍入。通用 UTC 小时客户端仍可查询原绝对区间，但不会自动变成当地日期。依据：`UsageAdminAPI`、`UsageQuery.init`、`web/src/features/usage/api.ts`、`round2-api.ts`。

### usage_daily、历史与偏移变更

关键现状：`SQLiteExecutionMaintenance.maintainExecutions/rollUp` 仅把超过 90×86400 秒、settled 且无 binding 的 attempt 汇总后删除原明细及 evidence；每批最多 100 条。故 `usage_daily` 通常已经没有可用于重算的明细，不是一个覆盖最近 90 天的物化副本。不能 DELETE 最近汇总后从 attempts 重新生成，否则会丢事实；也不能把仍在 attempts 的行另写入汇总而让现有 UNION ALL 重复计数。日序列目前合并 attempts 与 usage_daily，通用小时/详情只查 attempts（`SQLiteUsageQueries.daily/query`）。

拟升级至 schema v12（若实施前其他变更占用此号则重新分配，不复用 v11）：

- 新增持久 business-day 定义 revision 历史，记录 offsetMinutes、生效 UTC 秒和离线变更审计；同一 offset 多次启用也有独立 revision。
- `usage_daily` 每行保存 `offset_minutes`、`definition_revision`、`boundary_source`（`legacy_utc` 或 `business_day`），保留 day_epoch 为真实桶开始 UTC 秒、结束为 start+D；PK 加入这三个来源维度，避免旧 UTC 桶与新 UTC/当地桶冲突。是的，offset 必须随行保存，不能只存在环境变量中。
- 所有现存 v11 汇总标为 legacy_utc/offset=0/revision=0；不猜测仅凭日期或 last_used_epoch 能恢复桶内分布。当前保留的精确 attempts 在读取时按当前定义重算；包括尚未清掉的超龄、unknown、绑定记录。迁移不复制这些 attempt 到 usage_daily，因此“保留期内可重算”由精确源查询实现，无需全量物化。只有能证明逐条来源完整的聚合才可重建；当前 schema 没有这样的反向映射。
- 后续 rollUp 在汇总与删除的同一事务，以当前定义对 created_at 分桶，并记录当时 revision。以后改 offset，仍有细节的 attempts 重分桶；已淘汰的汇总保留原 offset/revision，即使它不是 UTC，也不能再精确重分桶。

拟扩展 daily 响应：`buckets` 为当前 offset 网格的统计，包含精确 attempts 与边界相同的归档（可合并数值但保留来源说明）；边界不同的汇总单列 `historicalBuckets`，携带 start/end、offset/revision/source、原有所有指标。按实际区间相交选择，边缘桶完整返回并标 `overlapsRangeBoundary`；它们不加入当前网格桶或其合计，不按比例拆分、不伪造小时。历史项先按自身完整 PK 聚合，再以来源+start+end 为展示组，容量超出时有界分页/续读，不能静默截断或无限扩大原 31 桶保证。拟每页沿用 31 个展示组上限，后续历史页独立游标；拟由 `/daily` 接受 `historicalAfter`，游标绑定查询范围、Key/模型、定义 revision 与最后来源分组排序键，严格校验，定义变化返回冲突。历史组按 start、offset、source、revision 稳定升序；响应带 `historicalNextCursor`，翻页只追加历史组、不重复累计主 buckets。所有指标遵守同一过滤、单快照/预算。

UI 历史区明确“原 UTC 日汇总，明细已淘汰，不能按当前业务日重算”，后续偏移历史标原 UTC±HH:MM。无详细时间仍单列 historicalWithoutTime。当前日与跨来源历史不能画成一条无说明的连续曲线；范围边缘提示完整历史桶可能含选区外记录。全 UTC 且无边界差异时原 buckets 结果保持，不制造空缺。现有 `UsageSummary` 的“更早 UTC 日汇总”和 `UsageOverview` 的历史读取流程必须随此调整。

### 迁移成本、扫描预算与崩溃安全

沿用 O03/O16 和 `SQLiteConnection` 的离线 `--migrate`、独占 flock、quick_check、SQLite Backup API 一致性备份及 fsync，服务不自动迁移。先用旧格式校验，完成备份、空间预检，后在单一 IMMEDIATE 事务内重建 usage_daily/索引、拷贝每条旧汇总一次并补来源、建设置历史、更新 restore 兼容字段、最后 user_version=12。不扫描 attempts/evidence 重新聚合，也不额外 VACUUM v11；v1—v10 升级仍须原前置步骤。索引引用和列顺序校验须同步，失败保持旧 schema。

定义 D 为迁移前文件页数×页大小，A 为旧 usage_daily 及索引大小：一致性备份/校验为全库 O(D)，表改建额外 O(A) 读写和索引成本；不是 O(全部请求 JSON) 聚合。保守沿用 `SQLiteConnection` 备份后 2D+8 MiB 重写空间预检及现有 StorageCapacity 可选工作水位；预检不能保证磁盘不会中途耗尽。不得编造生产秒数或承诺固定大小必能完成。合成大库验收记录 D/A、行数、耗时、峰值 WAL/空闲空间，并确认没有 attempts 全表 JSON 重算；备份复制现有 128 页步进和大小门禁的适用性须实测，不为大库静默绕过门禁（`SQLiteSnapshotMaintenance.copy`）。

在线查询继续 1 秒扫描预算、单 reader/单在途、50 ms busy、取消 progress handler；不在首个管理请求中迁移或建索引。离线迁移为一次原子维护任务，无 1 秒在线预算也无无依据的总时限承诺；复制按现有页步进可中断，表重建使用可取消 progress handler，取消则整体事务回滚并重试，不发布半成品。若大库实测不适合此离线事务，须维护者另审带持久 checkpoint 的分批方案后再实施，不能现场改成在线后台搬运。改 offset 的离线命令仅追加定义与审计，不扫全库重写历史。

备份/空间/写入失败不得开始或发布迁移；SIGKILL/重启后 SQLite 回滚到完整 v11，或看到完整 v12，不出现半拷贝 v12。v11 由新程序拒绝启动并要求重跑 --migrate；v12 必须核对持久定义后才恢复 intent。错误不删除备份、原库或降低安全水位。依据：`SQLiteConnection.init/backupBeforeUpgrade`、`SQLiteSnapshotMaintenance` 和 [快照维护](../../operations/snapshot-maintenance.md)。

### 切换日、跨午夜和在途执行

拟采用“立即重投影当前窗口”，不赠送一个空白额度日：应用设置后，对新的 `[start(now),end(now))` 从所有仍有精确准入时间的记录累计已知 Token，再决定新准入。旧定义今天的消耗可能部分移出或移入新今天，因此切换日可用量可能增减，达到新窗上限即拒绝；不会等到旧 UTC 午夜才生效，也不保证换 offset 不能增加当天可用量。此后按新边界自然重置，轮换/重启不清零。偏移修改是有审计的离线管理行为；频繁修改的治理影响必须在操作前说明。

事务只取一次 now；检查 Key 限额、记录 created_at、最终 window_id 和 admission_json 使用它。拟窗口格式 `business-day:<revision>:<startUnixSeconds>`（含 UTC 定义也使用此格式）；旧 `utc-day-*` 保持原值可读。准备 command 后等待跨午夜的场景，writer 在派发前按实际准入时刻重新赋窗口；定义 revision 过期则准入前拒绝并要求重新准备，不能重放已派发执行。所有入口，包括 pool、priming 和 unexpected execution，复用此路径。`ExecutionStore.admit` 拟返回事务最终确定的 ExecutionAdmission，`ExecutionCoordinator.execute` 必须直接用这个返回值构造 ExecutionContext；pool 的 admitSelectingAccount 也返回规范后的同一 admission，不能只在数据库偷偷换窗口而上下文仍持有旧 command。`keyTokenUsage` 拟接受已捕获的日区间，不再自行读 clock，reader 的摘要与提醒也传各自快照唯一 now。现有 `insertAttempt` 独立多次读 clock，`admitTransaction` 仅恢复库比较 utc-day，须一并收敛。

已经持久准入的 attempt 不修改旧窗口、policy/pricing、reserved、unknown_since 或 evidence revision。它可继续、最终化与迟到证据仍归原 created_at；在当前统计里按该准入瞬间投影，而不是完成日。reservations/unknown 是执行责任，不因日界或 offset 释放；最大并发继续全时间计数。切换采用停接单、按既有 shutdown 有界收敛；来不及完成的 intent 重启转 unknown，不能因为迁移或改 offset 再发送。依据：`ExecutionCoordinator` 调用的持久执行契约 E01—E05/E11、`SQLiteExecutionStore`、`SQLiteKeyGovernance`。

若恢复/时钟大幅倒退使“当前业务日”与无明细的旧汇总重叠，不能从其他 offset 桶推定精确 Token：保持维护门禁，要求核对/冻结至新日末；禁止忽略这些桶获得零额度。正常当前日仍在明细保留范围内，不应为每次准入扫描整段历史。此异常检测用归档时间索引、有界查询，失败关闭准入。

### restore、snapshot 与维护

`RestoreRecord.minimumFreezeUntilUnixSeconds/minimumReconciliationFreeze` 当前按 UTC 次日计算。拟持久保存恢复时的 day definition、恢复日最低冻结 UTC 截止以及首次核对日定义/截止；校验旧记录时把缺失定义解释为 UTC，保留原冻结。新恢复/首次核对均取业务日末与所有继承截止的最大值；后续改 offset 不缩短已承诺冻结，首次核对另取当前定义日末的最大值。冻结存为 UTC 瞬间，不因进程换环境而重解释。CAS、unknown 观察暴露、权限换发与账号重授权不变。

离线/在线 bundle 都携带 v12 数据库中的定义与历史来源；manifest schema=12，格式是否仍为 1 取决于是否增加 manifest 字段（本方案不需增加，定义在库内）。verify/readOnly/restore/migrate/status/reconcile/key-maintenance 的版本门禁都需接受 v12 并核对定义；备份读取历史定义不依赖当前进程配置。恢复默认沿用源库定义；目标环境不同必须先完成恢复屏障，再离线显式改定义，继承冻结不得变短。v7—v11 备份恢复升级为 v12 时按 UTC 源定义处理，不能把旧汇总标成目标 offset。保留 .restore-pending、空目标、generation 和旧绑定失效。依据：`SQLiteSnapshotMaintenance.restore/verifyBackup/status/reconcileFile`、`SQLiteConnection`、`SnapshotMaintenance.swift`、`CodexOneMain`；维护所有者与时长见上表。

### 回退至本分支之前的 v11 版本

v11 程序会在 `SQLiteConnection` 的 schema 门禁拒绝 v12；新增归档主键/字段及业务窗口字符串也未经旧程序验证。禁止只改 user_version、删列或把 offset 环境变量移除后原库启动；没有无损原地降级路径。面板单独回退且仍用 v12 后端可保留数据，但旧 UTC literal UI 不能配非 UTC 定义。

具体运维顺序（以后实施时写入升级指南）：

1. 升级前停服，用目标 v11 二进制创建并 verify 完整 bundle，保留对应全部解密密钥、配置和不可变二进制标识；迁移自动 raw 备份不替代 bundle。
2. 需要回退时停止新版本并有界收敛；用 v12 维护工具保存并验证当前完整 bundle，独立保留迁移后执行、unknown、权限及自动操作审计，不删除新库。
3. 准备全新空目标，以兼容的 v11 二进制和原主密钥恢复升级前 v11 bundle；恢复 v11 配置，移除新 offset 参数、使用 UTC。没有兼容 bundle 则保持停服，前向修复。
4. 用 v11 `--maintenance-status`、`--reconcile-restored` 按恢复记录的实际最低 UTC 冻结截止和 CAS revision 填写审计基线，披露快照至回退的缺失区间、未知执行与凭证旋转；换发 Key、账号重新授权，核对卡消费/priming，不从旧快照重放。
5. 冻结结束且既有恢复门禁通过后才启动数据服务/检查 ready；保留 v12 bundle 供核对。不得覆盖新库、重置余额、自动退款或共写。

恢复到旧快照的服务库会失去快照后新增用量/诊断、Key 管理与策略变更、定义 revision、业务日归档和后续操作记录；这些仍只在保存的 v12 bundle 中，未设计自动导回 v11。上游消耗与凭证旋转不会撤销。依据：[备份升级回退](../../guide/backup-upgrade.md)、[快照维护](../../operations/snapshot-maintenance.md)、`SQLiteSnapshotMaintenance.restore`。

## 二、首页“今日 Key 请求汇总”

### 当前字段、缺口与计量

`UsageAdminAPI.register` 的 `/api/usage/keys` 已返回顶层 start/end/timezone；每 Key 为 keyID、displayName、principal、enabled、admitted、succeeded、failed、cancelled、inFlight、pending、tokens（十进制字符串）、tokenUsageIncomplete、estimatedMicros（可空字符串）、lastUsedAtUnixSeconds（可空、全时间最近准入）。Core 类型为 `KeyUsageSummary`，读取为 `SQLiteUsageReader.keyUsage`。目前首页 `round2-api.ts` 的 schema 丢弃 tokens/完整度/费用/lastUsed 及顶层元数据，`KeyResults.tsx` 按请求量排序，默认活跃并可切“全部”。不能据此认定后端缺少 Token 或最近时间。

拟新增后端每 Key `inputTokens`、`cachedTokens`（可空十进制字符串）及 `cacheUsageIncomplete`。同一日区间、同一只读快照聚合，使用宿主 input（含缓存）与 cached，排除原生 Images 的不适用宿主指标；缺失标 partial，不能把 nativeImages 的兼容零当真实缓存计量。有已知下界但任一相关请求缺失缓存/输入时，缓存比率显示破折号及“证据不全”，不把下界比冒充精确比例。现有 lastUsed 在今日有准入的行必然也是今日最后准入，故无需新增另一个“最后活动”字段；它不代表最后完成时间。pending 不等于结果未明，保留接口但不用于显示结果未知。

Token 直接消费现有 tokens/tokenUsageIncomplete；保证与 Key 限额共用 `SQLiteKeyGovernance.keyTokenUsage` 的计量投影和同一个日区间：普通/预热/压缩为 input（含缓存）+output；缓存不重复加；原生 Images 为 imageInput+imageOutput；图片工具 token 不额外加到宿主 token。缺失/部分证据显示“≥ 已观测”与说明；无请求的行不展示，存在请求但全缺证据也不把 0 当可信完整消耗。不能用 `round2-api.tokenTotal` 的宿主 input+output 替代治理 tokens，后者无法覆盖原生 Images。后续优化聚合时先抽取同一计量 SQL 投影供 writer 与 reader 使用，避免为面板另造公式。依据：`SQLiteKeyGovernance.keyTokenUsage`、`SQLiteUsageQueries.metrics`、U12。

缓存命中率 = 今日 SUM(cachedTokens)/SUM(inputTokens)，以累计 token 加权，不平均逐请求百分比。没有适用用量、输入为 0、全缺失或证据不全都显示“—”；有完整输入且 cached=0 时 0% 是真实零命中，必须允许。需求中的“无用量时绝不 0%”不能解释为禁止真实 0%。分子不得大于分母；异常响应当无效数据处理，不钳成 100%。大整数先用 BigInt 安全求比、最后格式化显示，不能直接 Number 丢失精度。

### 行、排序、刷新与窄屏

- 仅首页使用 includeArchived=false，并过滤 admitted>0；启用/停用/到期不改变今日活跃定义，保留已停用状态。删除“今日活跃 / 全部”控件；零请求空态为“今日暂无活跃 Key”。Key 管理与历史 API 默认包含归档的语义保持。
- 六列依次为 Key、最近活动、请求、失败、Token、缓存命中率。失败形如 `39（25%）`，分母选 admitted，与面板请求数一致；取消/执行中/未明不计为失败，说明率是已准入请求中失败比例。没有准入前拒绝，失败不能用 pending 计算。
- 名称旁有非零“执行中 N”徽标；非零取消和结果未明在名称下的紧凑状态区显示，窄屏也不隐藏。结果未明仍为 admitted−succeeded−failed−cancelled−inFlight，保留非负一致性校验；它不等于待核对 unknown 或 token 缺证据。依据：现有 `KeyResults` 和 `round2-api` 校验。
- 名称优先 displayName，后备 principal；对于内部 `legacy-p-...` 后备名称改为“未命名 Key”，不在行内渲染该 ID。名称 hover/focus 提示及可点击详情显示完整 principal/keyID，移动端通过详情可达；重名依靠详情辨认。只改首页渲染模式，不全局改变 `shared/KeyName.tsx` 对其他页面的契约，也不改身份数据。
- 每次成功刷新按 lastUsedAtUnixSeconds 倒序，缺失置底，同秒按 keyID 稳定升序；复制数组排序，保持 React key=keyID。新请求可让行升到顶部，结算修订本身不改变顺序；不冻结旧排序、不动画交换。刷新时保留旧快照和更新时间，错误显示陈旧提示；日界到来时旧快照须标旧窗口，不能仍称今日。保留当前焦点/详情绑定 Key，避免刷新把点击目标换到另一 Key。
- 复用 `shared/ui/DataTable.tsx` 的响应式标签机制：大屏六列，窄屏每 Key 卡片式堆叠，首行名称/执行中/最近活动，随后请求与失败、Token 与缓存，非零取消/未明始终可见；名称可换行，精确数值可展开/提示，失败链接和详情均支持键盘与触摸。不得靠隐藏列或 hover 才能看异常。

高失败率拟采用保守的样本门槛规则：仅 admitted≥20、failed≥5 且 failed/admitted≥20% 时，用橙色强调失败单元格并标“失败偏高”；其余仍显示完整数率与链接，不警报整行。20/5/20% 是待维护者确认的产品提议，未声称来自运营数据或统计显著性；tooltip 给出规则，小样本不变成醒目红色。阈值边界须有测试。

### 失败链接与诊断兼容

现有 `web/src/features/usage/UsagePage.tsx` 已读取 URL 的 key/start/end/failedOnly/state 等，`UsageOverview` 有“仅异常结果”，`UsageAdminAPI.parse` 支持相应查询，故 Key+今日范围可复用。但 `SQLiteUsageQueries.predicate` 的 failedOnly 对 admitted 使用“failure 非空”，diagnostic 不排除；它不等价 `outcome.kind='failed'`，且 state=settled 也不是失败状态，不能假称今天就支持精确面板失败过滤。

拟加可选 `outcome=failed` 到 UsageQuery、API 严格枚举、web filters/URL/表单和导航记忆。该条件仅筛选 admitted 且 outcome.kind=failed，排除准入前 diagnostics，优先定义为精确结果过滤；与 failedOnly 同时出现时按 AND，state 继续独立表示执行状态。现有 failedOnly 行为保持，用于更宽的异常排查。

非零失败数链接至 `/usage?key=<编码ID>&start=<业务日期>&end=<同日>&outcome=failed&businessDayRevision=<当前revision>`（路由实际由当前 HashRouter 生成）。使用摘要返回的 start/end 与定义生成日期，不能点击时用浏览器今日重算。跨午夜仍打开行所属日期；revision 变化则提示重新选范围，不能静默查询新日。零失败显示普通 `0（0%）`；若以后允许点击零值也必须有正确空态。新筛选应让详情总数等于面板该快照 failed，晚到结果或刷新时刻不同可使后续计数变化，要显示更新时间而非承诺跨请求原子快照。

每 Key 首要失败原因本次不做。以后可在同一有界读快照按 Key+failure 分类聚合，按次数与固定枚举稳定取首位，并带统计时间/缺失说明；daily.failures 已有分类聚合但不是逐 Key 摘要，不应为每行额外发 daily 查询。依据：`SQLiteUsageQueries.daily`、`UsageAdminAPI`。

## 拒绝的方案

| 方案 | 拒绝理由与代价 |
| --- | --- |
| 只把 UTC 标签换成本地显示 | 限额与统计不同日，违背已定方向。必须贯通 writer/reader/API/UI。 |
| 浏览器时区或宿主 TZ/IANA/DST | 同实例不同设备结果不一致，DST 超出范围；固定 offset 简单可解释但需人工调整。 |
| 只支持整小时来保住旧校验 | 不能满足 +05:30；选择双小时网格和明确 origin，增加 API/web 校验成本。 |
| 把历史 UTC 桶整体平移/按比例拆分 | 没有明细无法知道真实分布，制造虚假本地日统计。选择明确历史来源与独立展示。 |
| usage_daily 不存 offset、以后按当前环境解释 | 后续切换无法区分来源，UTC 与本地桶可能冲突；增加 schema/索引和历史 UI 是必要成本。 |
| 开机自动迁移、在线热改 offset、首请求重建全库 | 违反显式维护和持久屏障，影响准入/扫描预算；选择停服命令和备份。 |
| 换 offset 清空当日额度、把在途迁窗或释放预留 | 会丢责任、赠送额度或重复记账；选择按准入秒重投影，保留不可变执行事实。 |
| 面板从每 Key 明细/日查询拼合、用费用或宿主 Token 推算总 Token | N+1 放大单 reader 压力，口径不一致；扩展一次摘要并复用治理投影。 |
| 以 failedOnly 冒充精确失败筛选、隐藏非零取消/未明 | 链接结果与计数不符、遗漏状态；增加精确 outcome 过滤和始终可见的状态区。 |
| 单个失败即红色、逐请求命中率平均 | 小样本误导、权重错误；采用明确待审阈值与累计 token 比率。 |

## 风险、待维护者确认与验收边界

已定方向不再作为待选项；以下为本设计需要评审的具体取舍：

- 是否接受整分钟 −12:00…+14:00 的支持边界、严格设置格式，以及修改需停服/显式应用的操作成本？UTC 到期日期维持独立契约是否足够清晰？
- 是否接受切换即按新窗口重投影造成当天已用/可用额增加或减少，而不是冻结至下一日？本方案不做额外额度补偿；恢复/归档覆盖不确定时仍需保守冻结。
- 是否接受历史分栏、边缘完整桶及分页增加 UI/API 复杂度？旧 UTC 日汇总无法无损转换是事实限制；不能用一个 timezone 字段隐藏混合历史。
- v12 重建汇总的维护窗口、空间和备份门禁须合成大库实测；长事务失败需重新执行。若超出可接受窗口，分批 checkpoint 设计需另审，未以未知吞吐承诺完成时间。
- 是否采用拟定的 20/5/20% 橙色规则、已准入请求作失败率分母，以及证据不全时缓存率显示“—”？这些是展示政策，不是运营结论。
- API 与 UI 必须配套；第三方依赖 timezone=UTC 或 UTC daily end 的管理员客户端需要升级说明。回退只能通过旧兼容 bundle，存在快照后本地记录缺口，必须人工核对。

验收必须覆盖跨午夜事务时间、限额边界、迟到累计修订、并发与 restart、只读/写满/取消/损坏迁移、恢复首次核对及偏移再变更；详细矩阵和命令见 [tasks](tasks.md)。本次仅执行文档检查，不把设计文档当作实现或兼容验收。

## 相关文档

[实施任务](tasks.md) · [用量规范](../../reference/specs/usage.md) · [管理规范](../../reference/specs/control-plane.md) · [运行规范](../../reference/specs/operations.md)
