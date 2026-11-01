# 用量治理

定义可信用量、估算、未知责任、限额与保留策略。

- U01：管理员显式 Key 请求/并发/预算/未结限额与每账号 16 并发为阻断项；全局请求、费用、未结统计只用于观察。金额是估算，不保证真实消耗绝对封顶。
- U02：准入事务校验权限、归属、显式 Key 限额、账号并发与存储安全并记录 intent；提交前不得 dispatch。
- U03：实际、估算与未知分别记录，完整度区分 complete/partial/unavailable；缺失不能记零，运营预留不能冒充真实最大消耗。
- U04：实际超预留必须如实入账；超出显式 Key 日预算拒绝该 Key 新准入，全局参考预算不阻断。部分用量不能当全部结清，保留原窗口/计价版本。
- U05：账本、迟到证据与人工调整必须幂等、去重和可审计；终态移交不等于可丢弃随后观察到的可信用量。
- U06：连接、活动 turn、待核对分开管理。unknown 从进入待核对起保留 24 小时；期内迟到证据照常结算，期满审计关闭，不再占待核对容量，不估算/不记零。重启恢复 intent 为 unknown 并从恢复时起核对。
- U07：全局、主体、身份未结数量/金额不阻断；Key 仅显式配置时生效。人工提前关闭与期满关闭共用状态转换及 release_unknown 审计，失败整体回滚；不得伪称已查到上游真实用量。
- U08：有可信证据才展示总体消耗上界；混有未知项必须标明无法量化，本地 credit 不等于真实 token/订阅剩余额度。
- U09：核心准入/绑定/结算保留执行配额，缓存不得耗尽；实际磁盘写满按核心故障恢复，不能保证清缓存就能结算。

## U10：订阅额度观测与按 Key 统计

必须从上游支持的可信额度观测获得账号窗口剩余/已用比例、重置时间与观测时间；区分主/次窗口及提供者实际含义，不把本地 token 或估算费用换算为订阅可用余额。不提供的字段标 unavailable，过期数据标 stale，观测失败不得归零或冒充刷新成功；刷新须有界，不用付费生成请求探测额度。

本地请求计数、输入/输出/缓存 token、图片用量和估算费用必须可按 Key 与时间范围查询，支持用量趋势及错误筛选。单位、时区、统计口径、迟到更新和完整度须明确，未知用量不得当作零。统计使用有界查询/聚合与保留策略，不能阻塞核心账本；Key 轮换的历史归属保持可解释。诊断不包含正文/图片，不因统计引入长期内容历史。订阅额度是账号级观测，按 Key 本地统计不得伪称提供者分配给该 Key 的订阅余额。

额度读取只对固定可信 usage 目标作被动 GET，不发送 Reserve opt-in、不消耗 reset credit、不用生成探测。最多 17 组限额（主 codex 加 16 个附加标识），可缺窗口/比例/时长/重置；不保存 credits 或私人账户字段。新鲜期限 300 秒，时钟倒退不视为新鲜。失败保留最近成功值并给出失败类别和时间；不从额度单一窗口推导所有模型必然不能执行。I22 的默认关闭预热是观察后的独立生成行为，用于启动已知空闲窗口，不用生成结果替代 GET 观察。窗口 JSON 额外保存可空 resetAfterSeconds，缺失仍未知。

统计按准入 UTC 秒、左闭右开小时边界，最多 31 天/744 点、明细 100 条；界面以 UTC 起止日包含两端，映射至次日零时结束。按 Key、模型、mode、用量状态和固定失败枚举筛选，失败终态与用量完整度独立；终态失败仍可有完整用量。超过 JS 精确整数范围的累计指标用十进制字符串传输。部分或缺失证据的已有数值标下界；全部缺失返回 null，不填实际零。历史缺少精确时间的记录单列，不伪造小时；轮换和迟到证据保留原时段/标识，不重复统计证据 revision。

全时间治理暴露只受 Key 筛选，不受时间、模型或错误过滤；区间查询不会退款或释放 unknown。单个只读 WAL reader、一个在途统计、1 秒 SQL 扫描预算，50 ms busy 等待，取消中断查询；不占核心 writer 队列。已识别 Key 的合法请求在准入前失败时只记脱敏诊断，已提交 intent 不重复记拒绝。诊断保留 30 天/最多一万条，压力/存储失败可缺失，不当作全部流量或账本；不消耗核心治理审计预留。

## U11：执行模式与历史记录

持久 admission 区分 generation、warmup、compact、priming；历史 JSON 缺失 mode 按 generation 解释，不改写旧记录。预热/压缩必须可独立统计，不混充普通生成次数；前三者计入本地统计与显式 Key 限额。priming 按 I22 使用内部主体，计入总体/账号统计、费用和未知暴露，不归到任意客户端 Key，也不消耗其限额。用量完整度继续按可信字段解释，预热或压缩成功返回不等于零消耗，缺失证据保留 unknown。

## U12：Key 本地治理窗口

托管 Key 的 requests/budgetMicros 按 UTC 日准入窗口计数；active、unresolved 和 unresolvedMicros 跨窗口、重启保持。客户端的三种执行模式均占用请求计数；缺失可信完整用量的执行继续占用未知暴露，直至按 U07 经审计关闭或收到完整证据；释放不补造用量。Key 五个限额字段均须显式出现，可分别为正整数（≤10¹²）或 null（不限）；缺字段、0、负数、超限及字符串拒绝。准入只跳过 null 的 Key 维度，统计、账本、预留和 unknown 责任仍照常记录。Key 限制与账号并发/存储安全在同一事务内共同生效，不能仅在传输层计数；轮换不重置 Key 限额。管理员可显式调整限额，但不能以此修改已发生的账本事实。

新 admission 保存模型及 Key revision；历史记录缺失字段时标为不可用，不猜测模型或改写旧记录。金额仍是估算费用，Key 的日预算不是订阅余额或真实消耗硬上界。

图片工具用量与宿主响应 token 分开记录和展示，不将工具 token 加入宿主 token 总数；费用按两份显式映射费率分别估算。缺少工具输入/输出用量时保持部分证据、unknown 和对应暴露，不能用图片已返回推导完整结清。图片工具指标为可空，历史缺失不补零。

原生 Images 无宿主执行，usage.input_tokens/output_tokens 映射 imageInputTokens/imageOutputTokens，input_tokens_details.text_tokens/image_tokens 如有则分别记录 imageInputTextTokens/imageInputImageTokens；有效 data[].b64_json 数量记录 images。按图片模型费率估算；缺失或畸形计数为不可用，不能以零替代，缺完整输入/输出计数保持 partial/unknown。结果有效性与结算完整度独立：200 空 data/非 JSON 结果失败，仍保存可信 usage。统计中 Images 不适用的宿主 token 及完全缺计数的费用返回 null，不把内部兼容计数当观测。沿用 usage JSON 的可选指标，不修改数据库 schema 版本或回填历史。

管理产品化只增加观测：`GET /api/usage/keys` 返回当前托管 Key（最多256）的 UTC 当日左闭右开窗口准入数、failed 终态数、unknown/在途待核对数、已观测估算费用及全时间最近准入时间。缺失费用/时间为 null；取消单独保留在用量报告，不计入 failed。摘要与 options/明细共用有界只读 reader、单在途及扫描/取消预算。轮换不清零。

用量 options 保留 `keys` ID 数组，新增 `keyOptions: [{id, principal}]`；明细新增可空 `principal`，按当前托管 Key 元数据连接，删除或未知 Key 为 null；priming 返回固定内部 principal。新增可空 `firstEventMilliseconds`、`totalMilliseconds`：从准入后执行上下文开始，以单调时钟观测首个上游事件及执行退出；无首事件为 null。仅新执行在既有 outcome JSON 存储，历史缺失为 null，不改 schema、不参与用量证据比较、计费或治理。首事件指解析出的流事件/WS消息，非流式指收到完整响应；不是下游首 token 时间。

## U13：输出前明确拒绝的零用量证据

“缺失证据不得记零”的唯一提供者拒绝例外：Responses/compact/Images 收到 HTTP 4xx 响应头（含429、正文不可读），或提供者 WS 握手4xx；以及 SSE/WS 首个解析事件为 error/response.failed，且有明确4xx状态或已识别的请求/权限/认证/额度错误码，没有输出条目或delta。状态存在时以状态为准，5xx不能被错误码改成零费用。已识别码包括 invalid_request_error/invalid_request、permission_denied/access_denied、model_not_found、content_policy_violation、unsupported_parameter 及既有认证/限流码；未知机器码不足以证明拒绝。首个非拒绝生命周期/未知事件也关闭此证据入口，采取保守边界。

上述执行记 settled、outcome failed，failure 保留既有分类，可信计数及费用为0、完整度complete，usage JSON 可选 `providerRejectedBeforeOutput: true` 注明依据；最终化释放预留和未知暴露。原生Images的图片计数为0，宿主token仍不适用、查询返回null；费用为可信0。拒绝不自动重放。无 schema 变化，历史 unknown 不回填。5xx、超时、断线、取消、已有输出后的错误、代理CONNECT拒绝或无法确认依据仍沿用 unknown/partial；已有可信用量不被清零。查询中可见真实零费用，不使用缺失值替代。

握手失败的可信拒绝证据及健康分类须在通知并行执行任务结束前记录到执行上下文；随后本地任务取消不得覆盖已观察的失败分类或丢弃该证据。沿用既有首次结果和上游事件门控，不等待数据库最终化，不新增重连或重放。

## U14：管理趋势与筛选合计

按日序列提供最近1—31天（缺省7、含今日UTC日）的已准入账本分桶，按Key/模型可筛选；请求、成功、failed、cancelled及非空failure分类独立计数，指标与逐条账本同口径，历史缺失不补零。尚无终态不记成功；拒绝诊断不混入该序列。现有查询totals提供所有筛选匹配项的合计与可空平均/P95首事件耗时、平均总耗时，不受分页影响。P95用非空样本nearest-rank；耗时不参与结算。进行中仅列intent，最多200条，不含正文/凭证；运行时未知观测保持未知。查询继承单只读快照、容量、超时与取消约束。API字段见[管理面](control-plane.md)。


## 未结执行人工释放

管理员可通过 `POST /api/executions/unknown/release` 人工核对关闭未知责任（解除显式 Key 的未结占用）。请求必填非负整数 `beforeUnixSeconds` 和 `expectedCount`，拒绝未知字段。在单一写事务内计数 `state=unknown AND created_at_epoch < beforeUnixSeconds`，不等于 expectedCount 返回 409，匹配则以 settled + closed_unknown_at_epoch 编码“已关闭·用量未知”，追加一条 release_unknown 治理审计。审计含截止时间、释放数量和执行时间；审计失败与状态修改共同回滚。0 条匹配可成功。intent、已有 settled、截止时间相等及之后记录均不变。

释放保留 outcome/failure 和可信用量证据，不补零、不产生估算；用量查询继续显示 unavailable，已有部分数值仅作为下界保留。unknown 及未结暴露计数相应减少。迟到部分证据不重新占用已释放容量；迟到完整可信证据仍可将统计修订为 complete。期满关闭由 Runtime 单一顺序 owner 每 60 秒处理最多 100 条，按 unknown_since_epoch ≤ now−24h 选择；审计 reason 区分 manual/reconciliation_expired。API/snapshot 投影状态 closed_unknown；完整迟到证据清除关闭标记，部分证据保留下界且不重新占用容量。迁移把既有 unknown 按结果时间/准入时间/迁移时间初始化核对起点；既有 settled 且非完整证据映射关闭标记。

### U10 补充：请求参数观察

准入将 Responses 的 reasoning.effort 与 service_tier 记录为现有 admission JSON 的 reasoningEffort、serviceTier；字符串须匹配 `[a-z0-9_-]{1,32}`，非法/超长/非字符串（含显式 null）记为 other，缺失语义为 null。requestMetadataRecorded=true 区分新请求未指定与历史无字段；可空值在持久 JSON 中可省略，管理 DTO 显式返回 null。原生 Images、预热与压缩无对应字段时同样为 null，不补写历史，不改 schema。此元数据仅观察，不改变转发内容、权限、准入判定或结算。

可信上游终态提供 service_tier 时，按相同规则记录 outcome JSON 的 actualServiceTier；缺失为 null，与请求值独立，不从请求推导。查询字段/筛选与界面默认说明见 A13 补充。记录中不包含正文或任意参数对象。

## U15：保留、汇总与参考阈值

全局 UTC 日请求 10000、估算费用 1000000000 微美元、明细 100000 行为参考阈值，达到 80% warning，超过只标明已超过参考上限。未知质量提醒用最近 1 小时准入数作分母，非客户端取消的 unknown/closed_unknown ≥10 条且比例 ≥20% 时 warning。每账号 24 小时峰值并发 ≥16×80% 时 warning；最近 10 分钟 ≥60 条且 ≥过去 7 天相同滚动时段计数中位数×5 时 warning（无历史视为 0）。quota_high 附最近 5 小时前 5 个 Key 的已观测费用下界、请求和缺失计数；不自动禁用或限流。

已结算/关闭且准入早于 90 天的记录由 Runtime 每轮最多 100 条，在同一事务内汇总至 usage_daily 后删除 evidence/attempt；intent 和核对中 unknown 永不按明细保留期删除。仍有有效绑定的明细暂缓删除。日汇总按 UTC 日×Key×模型×模式，并细分结果/失败/完整度/用量未知；保存全部可空指标的和、计数、最后使用时间，全部缺失仍为 null。日序列合并明细/汇总，Key 最近使用跨两者取最大；小时报表和请求详情仅含保留的明细，不将日汇总伪造为小时观测。unknownReasons 含固定失败枚举或 unspecified，usageUnknown 区别于尚待核对 unknown。日汇总长期保留，不含正文/对象 ID；其物理容量由存储水位保护。

每个新绑定保留 30 天，成功准入的续接/可信重发续期；只读查询不续期。迁移时所有旧绑定获 30 天宽限。到期立即拒绝读取，同一维护 owner 小批删除，不改变相关执行的核对期。此数值是本次建立的基线，既有文档此前只有“覆盖续接期”的原则要求。

关闭审计保留 90 天、每轮最多清理 100 条；它与其他维护审计的 1000 条容量隔离，自动关闭不会耗尽恢复/密钥操作的审计预留。其他审计保留原契约。存储压力非 normal 时整个可选维护暂停；恢复 normal 后由持久状态继续。每轮空闲页 ≥5% 时至多 incremental_vacuum(32)，不在在线维护中执行全库 VACUUM。

## 重置卡与观察边界

订阅配额可附可空的重置卡可用计数，仍是观察值，不改变本地 Key 用量、账本、预算或 unknown 责任。使用重置卡只请求提供者重置窗口，不回退本地累计用量、不伪造退款。列表和消费不进入生成用量；独立消费审计及到期调度见 I21，管理与结果解释见 A18。官方客户端 `/usage` 菜单透传和用量压力自动使用不在此能力范围。

## 相关文档

[文档导航](../../README.md)
