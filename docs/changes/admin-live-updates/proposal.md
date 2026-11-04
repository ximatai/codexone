# 首页实时管理概览

方向已确认，尚未实现；不表示已交付。推荐首页专用 WebSocket、共享有界采样、HTTP 降级。第一版不建业务事件总线，不扩展到其他页面。依据 [A07、A10—A13、首页摘要契约](../../reference/specs/control-plane.md)、[职责](../../architecture/ownership.md)及 [目录约定](../../development/layout.md)。以下“拟”及容量、频率均为本提案选择，非现有能力或测量结论。

## 现状与实际迟滞

前端路径以下以 `web/src/` 为根，后端以 `Sources/` 为根。首页主体为 `features/system-status/AdminOverview.tsx`、`ActivityOverview.tsx`；七个查询共用 `useOverviewRefresh.ts`：可见且自动刷新时每 15 秒，隐藏/关闭自动刷新后停止 interval；staleTime=15 秒，回到窗口可触发过期读取，另有手动刷新及写操作后的失效刷新。这些并非七个一致性事务。

| 首页数据 / HTTP 来源 | 周期 | 后端实际读取 / 变化频率依据 |
| --- | --- | --- |
| 运营数字、七日趋势 `/api/usage/daily?days=7` | 15 秒 | `CodexOneAdapters/ControlPlane/UsageAdminAPI.swift` → `SQLiteUsageReader.dailyUsage` → `Persistence/SQLiteUsageQueries.swift:daily`，聚合 attempts 与 usage_daily；有流量时随执行结果/用量提交改变，非逐 token 实时计数。 |
| 进行中 `/api/usage/in-flight`（最多 200） | 15 秒 | 同 API → `Persistence/SQLiteUsageReader.swift:inFlightUsage`，intent JOIN Key/账号，加 `SQLiteExecutionStore.liveFirstEvents` 内存值；开始、首事件、结束变化快，耗时按查询时刻计算。 |
| 今日 Key `/api/usage/keys?includeArchived=false` | 15 秒 | 同 API → `SQLiteUsageReader.keyUsage`，managed_keys、attempts、usage_daily 的分组/治理投影；准入/结算及 Key 状态改变时变化，业务日切换也变。 |
| 订阅账号/额度 `/api/accounts`（有界分页） | 15 秒 | `ControlPlane/AccountAdminAPI.swift` → listAccounts、凭证到期/更新时间元数据、quotaObservation、accountHealth；逐账号本地读取，GET 不请求提供者。策略/身份低频；冷却随请求失败/时间变化；额度来自既有被动观察，`CodexOneRuntime/AccountObservationSupervisor.swift` 默认扫描间隔 60 秒，读取更快不等于上游更实时。 |
| 存储/备份 `/api/runtime/storage` | 15 秒 | `ControlPlane/KeyAdminAPI.swift` 读取 storageObservation、backupObservation，无首页 SQL 聚合；`CodexOneRuntime/StorageMonitor.swift` 每次维护完成后等 1 秒；存储压力可能快变，备份低频。 |
| 提醒 `/api/attention` | 15 秒 | `ControlPlane/AttentionAdminAPI.swift:items` → `Persistence/SQLiteAttentionReader.swift`（账号/额度/健康、Key、执行、headroom 聚合）加存储、备份、协议名 registry；部分随执行快变，临期、陈旧、滚动窗口即使无写入也随时间变化。 |
| 治理余量 `/api/usage/headroom` | 15 秒 | `UsageAdminAPI` → `Persistence/SQLiteGovernanceReader.swift:headroom`，今日 COUNT/SUM、intent 并发、account_concurrency 的滚动峰值、明细数及 unknown 截止；并发变化快，参考阈值配置低频。storage 来自内存观察。 |
| 管理连接/生成就绪 `/api/system` | 挂载一次，手动重读；无轮询 | `features/system-status/SystemOverview.tsx` → `ControlPlane/AdminService.swift` 的 reportProvider；由 `CodexOne/CodexOneMain.swift` 组装池 readiness 或存储/配置/finalizer 状态。可变化却不会自动刷新。公开 LAN 风险条也使用此状态 DTO（`LANRiskBanner.tsx`）。 |

首页账号抽屉是额外的按需 HTTP 流程：`features/account-management/AccountManagement.tsx:AccountDetailPanels` 独立以 15 秒查询共享 headroom key（不受首页暂停开关统一约束）；`useAccounts.ts` 首次/手动/操作后读账号与 session，15 秒 timer 是本地陈旧时钟；授权状态另有约 1 秒轮询，500 ms 倒计时；`ResetCredits.tsx`、`QuotaPriming.tsx` 展开才读取配置，重置卡列表可能访问提供者（`AccountAdminAPI.swift`）。这些不是首页常驻采样数据，第一版不通过 WS 发送授权流程、配置或重置卡列表。

**能从代码确认的迟滞**：请求可能在两次 15 秒读取之间开始并结束，从进行中完全看不到；运行时长直接显示 `elapsedSeconds`，以约 15 秒跳变；就绪状态可长期停留在挂载时的值。`ActivityOverview.tsx` 的“秒前更新”每秒走动，不代表数据每秒刷新。不同查询先后完成会短暂显示不同采样时刻。

不能据此断言常规轮询导致整面板闪烁：`AdminOverview` 的 Skeleton、`OverviewStats`/`KeyResults`/进行中表格均使用 isPending，而非 isFetching；`shared/ui/DataTable.tsx` 虽在 loading 时替换整表，后台读取已有数据通常不会进入该分支；Key/执行行有稳定 ID。明确的局部替换发生于 `SystemOverview.reload` 主动设置 loading。实际视觉程度未运行浏览器验证。

**不用 push 也能改善**：用 startedAt/服务端采样耗时加本地单调时钟逐秒显示（断连标陈旧），状态手动重读保留旧值、后台刷新就绪状态；进行中单独缩短至 2 秒。无需把全部七组查询一起加速；后者会增加 SQLite 聚合负担。保留 Key 身份、焦点、抽屉和滚动是 A13 既有要求，不是 WS 自动带来的收益。

## 方案选择

| 方案 | 结合代码的成本与收益 | 结论 / 粗估 |
| --- | --- | --- |
| 改善轮询 | 复用上述 HTTP/取消/401/Query 缓存，局部计时与保留旧值最便宜；2 秒查询仍可能漏掉短请求，多标签每次分别做 SQL。共享缓存可以另加，但仍须处理 freshness 和寿命。 | 约 1—2 人日；可独立先合并作为降级体验。 |
| SSE | 单向数据足够，cookie 与自动重连适配；但 `Transport/AdminHTTPIngress.swift` 只接受完整 response.body.data，1 MiB 上限、5 秒写期限并强制 Connection: close，不支持长流；仍需新增长响应分支、背压、会话撤销。管理 Nginx 已关闭 buffering，但有 30 秒读超时。 | 约 4—6 人日总量；省 WS 帧处理，无法省共享生产/授权/寿命改造。 |
| WebSocket | 符合 owner 请求，支持 ping/pong；数据面已有 typed upgrader/peer 可参考（`Transport/ResponsesDataService.swift`、`WebSocketPeer.swift`），管理 ingress 当前没有 upgrade，不能只注册 Vapor websocket route，也不能复用数据 Key 授权。管理 Nginx 当前清 Connection 且未转发 Upgrade。 | **推荐**；约 5—7 人日总量含验收。较 SSE 多约 1 人日估算，成本可控。 |

WS 的收益是共享后端读取和更短的显示延迟，不承诺逐执行无遗漏事件或上游额度实时性。上述工期为阅读后的工程估算，尚无实现探针。

## 数据与生产方式

拟新增同源只读 `GET /api/overview/live` upgrade，固定 v1 协议，不接受 query、Bearer、订阅表达式或业务命令。HTTP 端点全部保留，管理写操作仍走 HTTP+CSRF。首次连接发 snapshot，之后发 **section 完整替换**（非逐行增量）：system、inFlight、daily、keys、accounts、storage、attention、headroom。仅发送变化的 section；每个 section 带 version、sampledAtUnixSeconds、lastSuccessAt、fresh/stale/unavailable 和安全 code；envelope 带协议版本、进程 epoch 与每连接实际发送时分配的递增 sequence（队列合并不消耗序号）。数字/null/业务日/精确 unknown 核对配对值沿现有 DTO，不创造余额或补零；推送不解除 mutation 的未知结果锁（`shared/useManagedMutation.ts`、`shared/session.tsx`）。

新 viewer 复用共享最新缓存；首 viewer 建立一次初始采样，其他同时连接加入同一工作，10 秒内给初始结果或逐源 unavailable。缓存各源独立时间戳，不声称跨源同一事务。重连必取完整 snapshot，无事件日志、无断点回放；epoch 改变清旧版本，单连接序列跳号视为失同步并重连。相同值的成功重采样通过合并的 freshness 消息推进采样时间，不能让“未变化”等同“已停采样”。

**第一版以周期采样为准**：一个共享顺序 producer，不按 viewer 发起查询，也不让每个客户端收到 invalidation 再自行 GET。拟 inFlight/storage 每 2 秒，daily/keys/headroom/system 每 5 秒，accounts/attention 每 15 秒；先 await 当前读取再调度，过期 tick 合并、不积压、不并行抢 reader。初始与后续调用应用查询/DTO 组装，不通过 loopback HTTP 自调用；复用 `SQLiteUsageReader` 单在途 WAL 快照、默认 1 秒 SQL budget/取消/optional storage gate，繁忙下一周期再试，不开新 reader 或重试风暴。各组不是硬实时 SLA；每组连续失败保留旧值并标陈旧。5 秒聚合比原 15 秒增加单 viewer 工作量，须以查询耗时/门禁验收，不能只比较网络请求数；如负担超预算，聚合退至 15 秒，快速组保持 2 秒。

| 真正的变更位置 | 已有信号的边界 / 第一版决定 |
| --- | --- |
| `Persistence/SQLiteExecutionStore.swift` 的 admit/结算及 ExecutionLiveObserving 三个回调 | 准入、用量/结果提交是可靠数据边界；首事件已有最多 16 条内存观察。现有回调更新字典，不是可订阅广播，不能称为已有推送总线。第一版采样该投影，短执行可能仍被漏过；若以后加 hint，须提交成功后发且不可阻塞 finalizer。 |
| `Persistence/SQLiteAccountObservations.swift:recordQuotaObservation`、`SQLiteAccountHealth.swift`、账号/Key 管理提交 | 持久成功后才算变化；ObservationSupervisor 现有 priming/reset-credit hints 是这些调度器私有入口，不可拿来当通用管理事件。先按 15 秒读取既有观察，不增加提供者轮询。 |
| `StorageMonitor.swift`、`CodexOneMain.swift` readiness、备份观察、协议 registry | 可读取既有 owner 快照，无统一管理 change stream。先采样，禁止生产器自行扫描磁盘/执行备份。 |
| 业务日、quota stale、冷却截止、滚动峰值/临期提醒 | 没有写入也会变化；即使以后事件驱动，仍需定时重算。 |

每个 viewer 只收编码后共享内容；新连接不重算 SQLite aggregates。最后一个 viewer 离开立即取消并 await 本功能采样，清缓存/计时器；新连接不得与旧 producer 关闭交叠。**零 viewer 没有本功能查询或 timer**；既有存储/额度/维护 owner 按原职责继续工作。先不引入跨业务失效总线，后续只有测得采样成本或延迟不够才考虑合并 dirty hints。

## 安全、容量与关闭

`ControlPlane/AdminSessions.swift` 当前 read 允许缺 Origin、认证会更新 lastActivity、session 仅内存，最多 16 个，24 小时 idle/7 天绝对寿命；logout/替换只删字典，没有连接通知。WS 必须新增准确连接绑定及撤销能力，不能只在握手认证一次。

- Upgrade 前要求唯一 session cookie、精确配置 Origin（拒绝缺失、null、重复、异源），沿用 Host、Sec-Fetch-Site 和混合认证拒绝规则；普通 Key/独立管理员 Bearer 都不能升级。此处比普通 GET 的 Origin 要求更严格。URL、subprotocol、日志不携 session/CSRF/新秘密；只允许标准控制帧，业务数据单向发送，无写命令。
- session owner 保留摘要到连接的有界绑定；logout、重登录替换、bind 清会话同步使连接不可再发送并关闭。发送前检查有效性，绝对/idle 截止 timer 到时关闭；每 15 秒在仍存活订阅上按现有读认证更新活动时间，等价于现有后台轮询维持会话，ping/pong 本身不延长绝对寿命。持续观看不是新的强制 24 小时登出策略；正常 HTTP 继续负责 Cookie 续期，socket 不设置 Cookie。会话失效关闭码 1008，前端用 `/api/session` 核对；401 清除 UI，网络失败仅标断连。
- 管理监听模型不变：`AdminHTTPIngress.swift` 默认 loopback、可显式允许私有 LAN 地址/peer，`AdminService.swift` 及 A10/A11 无 CORS；公网仍由独立管理 HTTPS 反代接入，不在数据 listener 开路由。LAN 的 ws 同样明文，保留既有风险条；HTTPS 用 wss，同源 CSP 须实际浏览器核验。

| 资源 | 拟 owner、上限及结束路径 |
| --- | --- |
| 总连接 | ingress 继续总上限 32，WS 子限额 8（跨 loopback/LAN 合计），每 session 最多 2；握手未通过不占 producer viewer；满返回安全 429 并 HTTP 降级，给登录/撤销留连接空间。WS 不长期占管理用例共享 16 并发 slot。 |
| 共享工作 | Runtime 监督一个 overview sampler，Core 仅定义所需查询/寿命端口和值；Adapters 实现 DTO、reader、session、NIO，入口组装，Adapters 不 import Runtime。每连接 transport supervisor 拥有 channel/写任务/心跳；取消一人不取消共享采样，最后一人离开才停止。 |
| 缓冲与帧 | 单 outbound 消息上限 1 MiB，初始 snapshot/section 超限返回安全不可用并降级，禁止无界拆包/截断冒充完整。每客户端最多 2 个待发消息、合计 2 MiB，另最多 1 MiB 在途；尽量合并尚未发出的同 section。超限或写 5 秒未完成关闭慢客户端 1013，不阻塞 producer，不创建额外写任务。入站控制帧按协议 ≤125 字节，拒绝客户端应用数据、压缩及无界分片，预解析即限额。 |
| 心跳/空闲 | 每 15 秒 ping，10 秒未 pong 或 10 秒未完成握手关闭；无业务变化仍心跳，不因安静关闭健康 viewer。页面隐藏/关闭自动刷新/离开首页主动断开，不留后台 WS；可见恢复重新 snapshot。 |
| shutdown | 先停止新 upgrade/订阅，标 stopping、取消 sampler 并 await 所有查询，再 1001 关闭连接；close handshake 最多 2 秒、随后强制关 channel，join 心跳/写任务。整体 5 秒截止，不依赖客户端回包；先结束本功能再关 usage reader/DB，沿 `CodexOneMain.swift` 的 runtime→reader→store→event loop 顺序。 |

内存预算依据 `deploy/compose.yaml` 的 768 MiB：保守按独立拷贝算，8×(2 MiB 队列+1 MiB 在途)=24 MiB，另共享缓存/编码工作合计硬限 3 MiB，payload ≤27 MiB。还须约束 NIO outbound 高水位和 decoder 缓冲，避免限额外重复编码/无限 write；对象、task、分配器开销不能由 payload 算出。拟验收新增 RSS ≤48 MiB（容器预算 6.25%）且混合数据面负载无 OOM，不代表现有峰值已有余量；不通过则减少 WS/帧上限或放慢采样，不能提高容器限额掩盖。1 MiB 初始快照能否覆盖最大合法 DTO 尚须合成边界验证。

## 失败、代理与迁移

前端由首页一个连接 owner 持有，并绑定 `shared/session.tsx` 的 generation；迟到消息、退役 HTTP 响应不得覆盖新会话/新传输。连接成功且有效初始 snapshot 后才停七组 interval；断连立即保留旧数据、显示“连接中/轮询/已陈旧”和各源最后成功时间。2/5/15 秒组分别超过 6/15/45 秒无成功采样即标陈旧；后台陈旧规则不取代提供者 quota 自身的五分钟 stale 规则。断连运行时长可继续本地计时但注明观察中断，不宣称请求仍在执行。

握手或初始快照 10 秒失败，立即恢复现有 15 秒 HTTP 轮询及 system 读取；浏览器无法识别握手 HTTP 错误时也不推断已退出，先核对 session。WS 用全抖动指数退避 1、2、4…最多 30 秒；连续 3 次失败后轮询期间每 60 秒探测一次，稳定连接 60 秒重置失败计数。同一时刻仅一个连接尝试；手动刷新沿原 HTTP 读取并按传输代际协调，不能由 socket 重放写操作。暂停自动刷新也停 fallback 周期，手动读取仍可用；恢复可见时重新取完整 snapshot。

`deploy/nginx-admin.conf` 当前 `Connection ""`、无 Upgrade、30 秒读/写 timeout。实现时只为精确 live 路径增加 HTTP/1.1 Upgrade/Connection 转发、保留 `$http_host`、不缓存/不重试/不记敏感头；建议 read timeout 60 秒，15 秒 ping 防空闲断开。其余管理路径保持当前边界，数据域名配置不变；`web/vite.config.ts` 的 `/api` 代理须显式启用 WS，不能改写 Origin。TLS/LAN、无 upgrade 代理和当前模板均须验收；旧安装未更新 Nginx 时自然 HTTP 降级，不强制部署中断。

无 schema、凭证或持久数据迁移；升级同步 web/后端，重启会清 session（`AdminSessions.bind`），客户端回到登录，登录后新 epoch/snapshot。WS 不恢复生成或执行事件，不改变 unknown/finalizer 责任。保留部署级关闭 live 的开关（默认启用，关闭返回安全不可用），可立即回到轮询；回退本次应用版本只失去推送，不新增数据库回退限制，原版本既有数据兼容限制仍适用。实现时同步 control-plane 的长连接例外、ownership、反代/操作指南；本次只新增提案、任务和索引。

## 显示连续性与组件选型

owner 要求绑定数据变化时组件按连续效果过渡。这与传输方式无关：HTTP 降级时使用同一套表现，不因回到轮询而变成跳变。现有栈为 Mantine 9、`@mantine/charts`（Recharts 3），无动效库；首页已不会因后台读取闪骨架，缺的是值变化时的连续过渡。

| 元素 | 选型 | 行为 |
| --- | --- | --- |
| 运营数字、Key 用量、余量数字 | `@number-flow/react`（MIT，单一用途，支持 React 19） | 数位滚动过渡，等宽数字，宽度变化不推挤相邻布局；金额、比例、千分位沿 `overview-format.ts` 现有语义；null/不可用不滚动为 0。 |
| 进行中、Key 行的进入/离开/重排 | `@formkit/auto-animate`（MIT，无依赖） | 只作用于明确的 tbody；行身份沿用稳定 ID。先在 `DataTable` 上做可选开关，默认关闭，不改变其他页面。 |
| 进度条、余量条 | Mantine `Progress` 过渡或 CSS `transition` | 只动画 transform/width；状态色 CSS 渐变。 |
| 七日趋势 | 保留 AreaChart，配置 Recharts 动画 | 同一图表实例从旧数据过渡；禁止因数据变化改 key 或重建实例。 |
| 运行时长 | 本地单调时钟 + 等宽数字 | 每秒直接走字，不做滚动；断连标观察中断。 |

不引入 `motion`：解压体积约 0.9 MiB，本版不需要手势或编排，两个小库足够。`auto-animate` 对表格行实测不佳时，可改用 `motion` 的 `LazyMotion`，但须说明证据与包体增量。不用 React 实验性 `ViewTransition`，不做整页过渡。版本在实现时精确锁定。

统一规则：

- 过渡 150—400 ms，须短于最快的 2 秒采样周期；新值到达时从当前显示值继续，不排队、不回放。
- 首屏 snapshot、断连恢复、标签页重新可见、会话切换直接落定新值，不滚动；变化幅度异常大时也直接落定，避免长时间滚动误导。
- `prefers-reduced-motion: reduce` 时全部关闭位移和滚动。
- 动画只呈现已确认的数据，不做插值预测，不伪造进度；动画中途的 DOM 文本和无障碍名称必须是真实值，屏幕阅读器不播报每次跳动。
- section 合并沿用 Query 结构共享：值未变的对象保持引用，配合 `memo` 只重渲染变化的单元；焦点、抽屉、滚动、表头和排序不被过渡打断。

验收：用合成 WS 帧和轮询两种来源，在真实浏览器检查大屏和窄屏；连续 60 秒高频变化下无布局跳动（CLS 为 0）、无长任务堆积，隐藏再回到页面无动画积压，reduced-motion 生效。记录生产包 gzip 增量，超过 30 KiB 须说明理由。

## 复用成本与首版取舍

以下为首版完成后的增量估算，依据实际页面读取方式；不顺便推送凭证、授权或所有历史查询。

| 页面 | 可复用部分 / 额外工作 | 估算 / 推荐 |
| --- | --- | --- |
| 首页内账号抽屉 | 已用 overview headroom key，可消费首页共享缓存，停其独立 15 秒 interval；配置、授权及确认不变。 | 0.5 人日，纳入首版，避免同 key 双重采样。 |
| 订阅账号页 | `AccountManagement.tsx`/`useAccounts.ts`：列表非固定轮询，详情 headroom 每 15 秒；需桥接本地 accounts state、草稿/未知锁与 Query 缓存，限定订阅字段。 | 1—2 人日，后续；首版离开首页即断连接。 |
| 访问密钥页 | `KeyManagement.tsx`/`useKeys.ts`：用量随读取/操作更新，无固定 interval；可复用今日 keys，但首页排除归档，不等同“全部”策略列表。需新范围与表单冲突保护。 | 1—2 人日，后续；不能以首页列表覆盖完整 Key 数据。 |
| 用量页 | `usage/UsageOverview.tsx` 保持 applied filters、固定窗口/分页、失败旧快照；全局首页聚合不满足任意查询，自动刷新会扰动历史阅读。 | 2—3 人日，仅未来评估“有新数据”提示，首版排除。 |
| 公共连接/风险条 | `SystemOverview.tsx`、`LANRiskBanner.tsx` 可在已登录首页复用 system section；未登录仍取公共 `/api/system`，不得为此开匿名流。 | 0.5 人日，首页就绪面板纳入首版；全站连接寿命后续。 |

## 验收与待决定

验收必须经真实本地 HTTP upgrade、WS 帧、SQLite、代理与浏览器接口，用合成管理员/账号/请求和假上游；不得以 sampler helper 测试替代。详见 [任务](tasks.md)。覆盖取消/断连/慢端、会话到期与撤销、并发/零 viewer、重启、不可写存储及大窄屏；不调用真实订阅或 OpenAI。

owner 已确认（2026-11-04）：

1. 首版采用 WS+共享采样，不做每次执行必达事件；进行中目标 2 秒、聚合 5 秒、账号/提醒 15 秒，短执行仍可能错过。
2. 总计 8 连接、每 session 2 个；其他页面后置，超额显示轮询模式，不拒绝管理页面使用。
3. 首页数据变化按上文“显示连续性与组件选型”过渡。

本次仅静态阅读；尚未验证实际闪烁程度、查询耗时、最大 DTO 大小、RSS、NIO upgrade 组合、浏览器 CSP/代理表现。频率、内存和工期均须实现验收校准，不能作为现有兼容或容量承诺。

## 相关文档

[任务与验收](tasks.md) · [管理规范](../../reference/specs/control-plane.md) · [运行职责](../../architecture/ownership.md) · [贡献指南](../../../CONTRIBUTING.md)
