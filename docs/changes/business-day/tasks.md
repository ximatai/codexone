# 实例业务日与首页 Key 汇总实施任务

状态：设计待维护者评审；本次无实现。依据：[proposal](proposal.md)。以下按依赖顺序实施；第一至六阶段交付业务日，第七阶段才能叠加面板。复选框只在实际完成与记录验证后勾选。

## 1. 评审与契约冻结

- [ ] 维护者评审 proposal 的设置格式/分钟范围、切换日重投影、历史分栏、离线操作、回退及异常冻结；确认 schema 目标号未被占用。
- [ ] 明确 API businessDay/timezone/revision、小时 origin、历史页游标与容量、旧客户端兼容说明；维护者同意后才改运行代码。
- [ ] 确认面板失败率分母/阈值、缓存缺证据及 UTC 到期输入保持的取舍；面板审批可与业务日独立，但不能提前上线本地“今日”。

验收：没有未说明的治理/恢复政策，所有未决项有记录，方案仍符合 U10/U12/U14、E11 与 O03/O16。

## 2. Core 日函数、配置和组装

- [ ] 实现 BusinessDayDefinition，单一定义 start/end/boundary/window；WallClock 保持纯时钟，去掉生产 utcDay 业务调用。
- [ ] RuntimeConfiguration 严格解析 CODEXONE_BUSINESS_DAY_OFFSET；入口配置错误退出 78，不回显原值；help/check-config 显示非秘密规范值。
- [ ] 同一定义注入 gateway、priming、store/reader、API、snapshot/维护命令，不按设备或进程局部时区推断。
- [ ] 单元测试 UTC、正负 offset、+05:30/+05:45、恰在/前后边界、跨月/年/闰日、负秒向下取整、支持范围/溢出与无效格式；缺省 UTC 维持结果。

验收：给定同一 t/定义，所有路径算同一 UTC start/end；固定日长 86400，DST 不参与。测试扩展 `WallClockTests` 与 Runtime 配置相关测试，不改用真实时间等待午夜。

## 3. schema、离线迁移与设置变更

- [ ] 实现 v12 定义历史/审计及 usage_daily 来源列、PK/索引、列名 INSERT 和 schema/只读兼容校验；旧汇总全部标原 UTC，不从 lastUsed 猜分布。
- [ ] --migrate 在实例锁下先 quick_check、完整性备份/fsync 与空间检查，再事务重建汇总并最终发布版本；保留现有低版本前置迁移。
- [ ] 实现 --apply-business-day：先备份、事务追加 revision/审计，普通启动拒绝配置不匹配；改回 UTC 或重复 offset 不擦历史。定义变化使旧 revision 请求可检测冲突。
- [ ] 合成迁移用例：空库、v11、低版本、已有混合未知/汇总、超龄仍有 binding 的明细；重复迁移无重复汇总/新备份副作用。逐指标比较迁移前后守恒和 null/下界语义。
- [ ] 故障注入：锁竞争、备份中断、空间预检不足、只读目录、写满/同步失败、损坏表；事务前/复制中/表重建中/版本发布前后 SIGKILL 并重启，证明只出现完整旧版或完整新版，不开放半迁移服务。
- [ ] 合成大库记录 D/A、行数、耗时、峰值 WAL/磁盘和扫描计划；证明无 attempts/evidence 全量 JSON 重聚合，保留复制页步进/大小门禁。若超出维护窗口，先重审 checkpoint 方案。

验收：失败不丢源库/备份、不降级水位、不静默 ready；现有 usage_daily 事实与精确 attempts 不重复不遗漏。离线命令无网络依赖。

## 4. 准入、限额和执行责任

- [ ] writer 事务只捕获一次 now，统一用于 Key Token 区间、created_at、最终窗口及 admission_json；admit 返回规范后的 admission，coordinator/context 与数据库一致；pool/单身份/priming/unexpected 路径覆盖，恢复库不再硬编码 utc-day。
- [ ] 保留旧窗口可读、原 policy/pricing、预留与 evidence 幂等性；统计按精确准入秒重投影，当前限额与摘要共用 Token 投影。
- [ ] 真实 SQLite 并发测试：command 准备在午夜前、排队后准入在午夜后；多个 Key/同 Key 同时跨界，达到限额时拒绝后续准入、新边界恢复；窗口/准入秒不矛盾。
- [ ] 覆盖切换日已经有消耗、切换前后当前窗重叠/不重叠、再次变更和改回 UTC、轮换/重启不清零；+05:30 的 UTC 非整点边界。
- [ ] 覆盖切换时 intent/unknown/预留、关机超时后重启恢复、迟到/重复/乱序 evidence，核对期跨日不释放；新日已用上限不阻止原执行如实结算。
- [ ] 存储不可写时拒绝新准入、dispatch 不发生，已有持久 intent 仍可恢复；时钟倒退/归档无明细覆盖当前日时保守维护冻结，不推算零用量。

验收：U02/U04/U05/U12 与 E01—E05/E11 不弱化；不增加 Token 预留或绝对封顶承诺。

## 5. 统计、维护、备份恢复

- [ ] SQLite 所有连接注册委托 Core 的 business_day_start；日 SQL/rollUp 不散落 offset 除法；小时 query 统一 origin。
- [ ] 精确 attempts 按当前定义查询；rollUp 与删明细/证据原子且保存来源。历史不同网格独立分页，返回原始完整区间和边缘标识，不伪造小时或混入当前桶合计。
- [ ] 扩展 `UsageQueryTests`/`GovernancePostureTests`：日桶、Key 摘要、headroom 同窗口；过滤、空日、null/下界、原生 Images、归档边缘、两次 offset 变化及相同 offset 不同 revision；合计无重复丢失。
- [ ] 保持单 reader/单在途、1 秒扫描/50 ms busy/取消/低盘门禁；大数据/并发 finalizer 下验证超时安全 429、取消不阻塞 writer、不伪装空结果。
- [ ] RestoreRecord 持久冻结定义/下界；旧记录缺失按 UTC 验证，新恢复/首次核对按当前定义取最大截止，后续变更不缩短继承冻结。
- [ ] 更新离线/在线 snapshot、verify、restore、status、reconcile、key-maintenance 的 v12 门禁和定义传递；旧 bundle 迁移保持 UTC 来源、目标 mismatch 走显式命令。
- [ ] 扩展 `SnapshotMaintenanceTests` 及合成 CLI 演练：.restore-pending 中断、源定义不同、跨日首次核对、已有更长冻结、CAS 冲突、冻结期间改 offset、恢复 intent/绑定/账号权限和自动操作屏障。
- [ ] 演练 v12→升级前 v11 bundle 的完整回退步骤：当前 bundle 保留、空目标、旧配置/UTC、换 Key/重授权、缺失区间基线与最低冻结；无 bundle 则停服。记录快照后记录只留在新 bundle 的限制。

验收：日统计和限额一致，历史来源可解释，恢复不借改变日界提早 ready；滚动时长、provider windows 与 backup 周期保持。

## 6. 业务日 API、web 与规范交付

- [ ] UsageAdminAPI 添加 businessDay/revision/timezone/generatedAt/窗口、历史分页；daily end 对齐业务日，通用范围支持同网格小时，保持旧 UTC 小时绝对区间。
- [ ] API 契约测试实际路由：默认 UTC 兼容、非零 timezone、非法/重复/未知参数、错误 revision=409、错日界/异网格/超过31日=400、31日744桶边界、+05:30、滚动24h未变、认证/no-store/容量不退化。
- [ ] web 先取定义，再建默认/快捷日期；共享日期换算与 formatter，替换 usage/system-status/Key 日限额 UTC 假设；缓存和视图记忆隔离 revision，旧响应不能覆盖新设置。
- [ ] web 校验 timezone/offset 对应、窗口/桶序列/整数/容量；保持到期输入 UTC 和原 expiresAt；测试不同浏览器时区得相同业务日期与边界，小时标签与实际 origin 一致。
- [ ] 浏览器用合成 API 操作今日/自选31日/历史分页/偏移变化/陈旧数据/错误/回退导航，检查大屏和窄屏；不使用真实运营截图。
- [ ] 同步 U10/U12/U14、控制面和 O16、ownership/configuration/backup-upgrade/snapshot-maintenance；更新 STATUS/CHANGELOG 时准确区分已交付与待验收，清理被替代的旧首页筛选契约。
- [ ] 实际运行并记录平台/命令/结果：`python3 scripts/check_docs.py`、`./scripts/verify.sh --backend`、`./scripts/verify.sh --web --chrome`（平台适用时）、web lint/format:check/test；缺工具或平台范围如实记录。

验收：仅业务日交付时原首页功能仍可工作，UTC 缺省自托管用户行为不变；非 UTC 版本说明明确 API/UI 需同步升级。维护者确认后才进入面板交付。

## 7. 叠加首页 Key 面板

- [ ] 摘要保留现有 tokens/完整度/lastUsed/元数据，补 inputTokens/cachedTokens/cacheUsageIncomplete；同一日/快照聚合，复用治理 Token 投影，避免 N+1。
- [ ] 新增精确 outcome=failed 从 Core→SQL→API→web URL/表单/视图记忆；failedOnly 原语义保持，diagnostics 不混入该筛选；覆盖与 state/failure/failedOnly 的组合。
- [ ] 六列实现；固定 admitted>0、未归档、lastUsed 倒序与 ID 同秒稳定次序；刷新采用完整快照，保留焦点/详情和错误陈旧标记，不原地修改缓存数组。
- [ ] 隐藏首页 legacy-p 行内 ID，名称后备/hover/focus/触摸详情可达；执行中徽标、非零取消/结果未明始终可见，停用标记保留。
- [ ] 缓存使用累计 cached/input，测试无用量/0输入/缺字段/部分证据/原生图片/真实0%/大整数/异常分子；Token 对普通/预热/压缩/原生图片/图片工具与限额完全一致。
- [ ] 失败 count/rate/阈值边界与小样本测试，失败链接带 Key、行所属业务日、outcome 与 revision；跨午夜点击、revision变化、后退/刷新仍明确查询范围。合成数据库证明精确筛选计数等于同快照摘要 failed，准入前拒绝不混入。
- [ ] 组件及浏览器验收：移除全部切换、仅拒绝 Key 不出现、停用有准入仍出现、归档隐藏、空态、加载/失败/陈旧、刷新重排、同秒、非零取消/未明、大屏六列与窄屏堆叠、键盘/触摸详情与失败链接。
- [ ] 运行相关后端/API 定向测试和 web lint/format:check/test、浏览器关键流程，再完成相关 verify；用合成截图和验证记录说明平台/局限。
- [ ] 更新首页规范与 STATUS/CHANGELOG；核对业务日与面板分别可评审，面板不引入 schema 改动或 top failure reason。完成后把结论归入规范，依仓库约定回收已完成过程文档。

验收：面板只显示今日活跃 Key，六列、排序、异常可见性、精确失败跳转与 Token/缓存口径符合已批准方案，顶部今日和 Key 限额共用业务日。

## 相关文档

[设计提案](proposal.md) · [变更约定](../README.md) · [验证约定](../../development/verification.md)
