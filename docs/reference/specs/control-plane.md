# 管理产品规范

定义管理认证、操作与诊断的公开行为约束。

- A01：管理台必须支持安全初始化/登录、上游账号生命周期与授权状态、Key 创建/撤销/轮换及有效策略查看；不得显示明文上游凭证。
- A02：创建 Key 必须分别呈现对话模型范围和图片生成权限；模型目录与最终可执行策略一致，明确继承/禁止/允许语义，不展示必然被权限拒绝的可选组合。
- A03：必须能查看请求阶段、账号选择/归属理由、用量完整度、预留、超额和未知成本；支持可审计核对，不提供绕过账本直接改余额的入口。
- A04：必须展示短期缓存的状态/容量/到期及删除结果，不默认提供正文/图片历史浏览；恢复不可用不得表示为生成失败或自动重新生成。
- A05：备份/升级/恢复操作必须显示影响和维护状态；危险操作按实际影响确认。静态 SPA 不含上游秘密，管理 API 不能直接修改共享运行态绕过应用用例。

- A06：首个管理入口必须明确 DTO 的 ID、UTC 时间、用量/金额单位、权限继承、错误 envelope 和 secret write-only 规则，以契约夹具或选定工具约束两端；不得直接复制领域/数据库类型作为前端模型。同源/反代、CSRF、session 与管理监听边界须在管理功能验收，不能推迟至发行。

- A07：loopback 管理 `GET /api/system` 提供只读的服务/就绪/先决检查摘要，不暴露秘密。管理台须区分连接中、连接失败可重试、服务已连接但网关未就绪。状态请求（含响应正文读取）最长等待 10 秒，超时进入可重试失败态；卸载或重试后的迟到响应不得覆盖当前状态。DTO 契约样例由后端编码测试和前端校验共享，不直接导入领域类型。

- A08：账号界面必须展示 U10 的订阅窗口、额度、重置与观测时间、stale/unavailable 状态；Key 界面必须提供时间范围用量/趋势，并支持按 Key、模型、时间和错误筛选请求诊断。必须区分上游账号额度、本地治理限额与估算费用，不要求复制旧平台全部图表或预测功能。普通 Key 能读取的统计须限于其授权主体；全局账号额度是否向下游披露由明确策略控制。
- A09：管理产品与迁移验收必须包含账号接入、模型目录/选择、Key 创建/禁用/轮换，以及 generation/edits 共用图片开关；不得仅在数据库人工配置后声称产品闭环。迁移状态和回退影响须明确，不能默认保留全部旧 Key 或旧会话。

## A10：本机 Key 管理 API

仅在配置独立管理员凭证文件时提供 `/api/keys` 的创建/有界分页、更新及轮换命令。文件按 owner/权限/类型和容量校验；管理员 Bearer 与普通 Key 分离，不接受 `co1_` 数据 Key 格式或复用 legacy Key 摘要。此入口默认仅 loopback，允许 O12 的显式 LAN 例外，不启用 CORS。无浏览器管理客户端可用独立 Bearer，但该分支拒绝 Origin、Sec-Fetch-Site 和 Cookie；浏览器按 A11 使用 session，混合两种认证明确拒绝。

输入/输出 DTO 与领域对象分离：时间为 Unix UTC 秒，金额为微单位估算，limits 必须显式包含 tokens/active，每项为正整数（≤10¹²）或 null（该 Key 维度不限），缺字段及无效值拒绝；创建/更新/读取保留 null。界面逐项选择“不限”并在列表、详情和用量显示。创建/轮换仅在成功响应返回一次 secret，列表与普通更新不返回原文或摘要；若成功响应丢失，应查询元数据后显式轮换，不能找回旧原文。更新/轮换携 revision，冲突返回 409；未知字段拒绝。错误 envelope 仅含安全 code/message/request_id，响应 no-store。

管理入口最多 32 个连接，Key/账号管理用例共享最多 16 个并发，另受数据库普通队列容量约束。NIO 在进入 Vapor 路由前收齐正文：最多 8 KiB，从接受连接开始绝对读取期限 10 秒，超时关闭连接、不派发用例，持续小片段不能延长期限，不保证超时 JSON envelope。单请求响应关闭连接，输出最多 1 MiB、写入期限 5 秒。Key 总数最多 256（含已归档），列表按 ID 每页最多 64；archived 缺省/false 只列未归档，true 只列已归档，同一过滤内按 after 游标分页。普通变更最多消耗 4096 条审计；另预留 256 条供 enabled→disabled 的真实撤销，总上限 4352。普通容量满后禁止创建/启用/轮换及重复禁用，因此不会消耗新撤销位置，所有现存活动 Key 仍可各禁用一次并持久审计。审计记录动作、revision、UTC 时间和非秘密权限快照；不删除历史。此临时容量边界须在后续诊断/保留策略功能收敛，不代表长期容量验收。

## A11：同源管理会话与静态界面

`POST /api/session` 接受必填 username（精确等于命名常量 admin）、独立管理员 secret 和可信浏览器来源，返回一次 CSRF 证明并设置 `__Host-codexone_admin`：HttpOnly、Secure、SameSite=Strict、Path=/、Max-Age 为绝对剩余秒数（最长 604800）、无 Domain。`GET` 获取当前证明，`DELETE` 校验后撤销并清 Cookie。session 由管理服务持有，最多 16 个，滑动空闲寿命 24 小时、绝对寿命 7 天（均为命名常量），边界时刻过期；每次认证通过刷新活动时间及 Cookie，续期不越过绝对截止，访问时清理过期记录；只保存 token 摘要和内存 CSRF，重启失效。用户名缺失、错误、大小写不同与密码错误返回相同 401/code/message（request_id 每请求独立），未知字段拒绝。登录采用标准 form，默认 admin 的 username 输入框使用 name=username、autocomplete=username；密码框使用 name=password、autocomplete=current-password，支持浏览器识别凭证保存，前端不在本地存储保存凭证。独立 headless Bearer 路径不变；现有连接/并发/期限限制保持，基线无单独登录失败次数限速，本次不新增策略。重新登录可替换当前 session，旧/过期 Cookie 不得造成无法重新登录。管理员文件更换须重启生效。

所有浏览器请求严格校验 Host；变更须同时有精确可信 Origin 和 CSRF，读请求有 Origin 时也须一致。Sec-Fetch-Site 若提供只接受 same-origin，重复/混合认证和重复 Cookie 拒绝。默认 origin 来自实际 loopback 监听端口；反代须显式配置公开 HTTPS origin，不信任任意转发头，不从请求 Host 推导来源。HTTP 非回环 origin 只允许 O12 LAN 模式，主机字面量须与配置监听地址相同（按 IP 值比较）；不接受别名或从请求推导。只有此种 origin 的 session cookie 改名 `codexone_admin` 并去掉 Secure，保留 HttpOnly、SameSite=Strict、Path=/、无 Domain 及原 Max-Age/续期/清除规则。HTTPS 与回环 HTTP 的 cookie header 保持逐字节不变。Host/Origin、CSRF、重复/混合认证、寿命与容量规则全部保留。

`GET /api/keys/options` 提供配置的模型 ID 供表单选择，不含上游指导或凭证。Key 界面分别选择对话与图片模型的“全部模型（跟随配置）/指定模型”以及五类治理限额，不把它们称为订阅余额；本功能不代表图片权限或账号池已交付。创建/轮换成功后原文仅保留在当前页面内存，关闭、离开、登出或五分钟后清除，不写浏览器持久存储。CAS 冲突刷新并由用户重新确认；写入结果未知不自动重试，刷新核对后才能继续；登出未确认须清本页秘密并明确提供重试。

可选静态目录只在启动时读取为不可变快照，允许 index.html（64 KiB）及 assets 下最多 32 个 JS/CSS（各 1 MiB、总计含 index 最多 4 MiB）。目录及文件须由进程用户或 root 持有、不可被 group/other 写；拒绝 symlink、非普通文件、硬链接及未知资产类型。仅服务精确路径，不回退任意文件或提供数据目录。HTML/资产设置 no-store、nosniff、禁止 frame/referrer 和仅同源脚本/样式/连接的 CSP；API 复用 A10 的容量与安全错误。


## A12：账号管理与一次性授权入口

配置独立账号主密钥后提供 `/api/accounts`，复用 A10/A11 的认证、来源、CSRF、容量与 no-store 错误契约。GET 按 ID/after 有界分页，最多 64 条；公开账号 DTO 的身份字段为 id、displayName、revision、credentialVersion、mode、authorization 和 createdAtUnixSeconds，另含可空的 accessExpiresAtUnixSeconds 与 credentialUpdatedAtUnixSeconds，另有 A13 的非秘密观测摘要，不返回 namespace、刷新 intent、明文/密文 token 或主密钥。到期字段由应用层读取并解密已有凭证后只提取 Unix 秒元数据，适配器不得获得凭证明文；未知或取值失败返回 null，不新增 schema。最近更新时间取已有account_events中create_verified/reauthorize_verified/refresh_commit的最后提交UTC秒，不用模式/显示名更新或刷新开始/失败时间；缺少可靠审计时返回null。详情以本地时间及相对时间展示，null显示“不可用”，不返回令牌内容或摘要、不新增schema。

PUT `/:id` 接受 revision/mode，POST `/:id/refresh` 接受 revision；状态冲突为 409，存储或提供者不明为安全 503，不透传错误正文。

POST `/authorization` 接受 target:null 创建新账号流程，或 target:{id,revision} 重新授权；可选 method 为 device（默认）或 callback，拒绝其他值及未知字段。设备码创建响应为 flowID/method/userCode/verificationURL/expiresInSeconds/intervalSeconds；创建失败返回 flowID/method/expiresInSeconds/failureCode（404 未开启为 device_code_unavailable），不包含设备私有 ID。回调响应为 flowID/method/authorizationURL/expiresInSeconds。GET `/authorization/:flowID` 返回 status（pending/completed/failed/expired）、expiresInSeconds，pending 设备码包含 userCode，completed 包含 accountID，failed 包含 failureCode。POST `/authorization/:flowID` 只接受 callbackURL，且仅用于回调流程；DELETE 取消并等待本 owner 的流程退出。GET/DELETE 对错误 owner 或未知流程返回安全 409，不泄露流程是否存在；状态读取拒绝查询参数。owner 从已认证 session 或独立 headless 管理凭证得出，不从请求 JSON/查询参数接受。流程信息不写持久缓存。不同 session/headless 域不能消费彼此流程，认证过期后须重新开始。其余责任遵循 I16，不能自动重发授权码或刷新 POST。


管理页面仅提供账号启用/禁用，禁用及 Key 禁用/轮换须先确认影响。历史排空账号保持原状态并明确提示，可显式切换启用/禁用；底层排空协议保留兼容。账号排空不接收新会话请求，已有身份关联续接仍可派发；禁用阻止后续派发（包括续接），两者均不主动取消已经派发的请求。Key 禁用使持有该 Key 的客户端后续请求立即失败；轮换使旧凭证立即失效。

授权失败 failureCode 取 I16 的 provider_rejected、exchange_failed、identity_mismatch、verification_failed、revision_conflict、device_code_unavailable、authorization_failed；最后一项保留通用回退。API 客户端必须接受新增代码并对未来未知代码回退，不把新代码当作响应损坏。前端仅接受有界代码标识，不显示未知原文；每种已知代码在授权对话框有中文解释。回调 POST 沿用安全错误格式，令牌端点以 400/401 拒绝兑换时返回 409/authorization_required（按状态判断，不读取错误响应体），其他兑换失败为 503/account_unavailable；前端失败后先 GET 本 owner 的已消费流程状态，再 DELETE；清除一次性输入及授权链接，只保留终态解释，不重发 callback。读取失败仍沿用未知结果锁与账号核对。旧客户端可能拒绝新代码，升级须同步 UI/API 客户端；无 schema 变更，内存流程不会跨版本/重启恢复。

账号页面分别展示使用策略与授权状态；新账号保持禁用，刷新失效/授权未知引导重新授权，不能以刷新按钮自动重用失效令牌。设备码默认弹窗显示可复制 user code/验证链接、倒计时与轮询状态，完成结果保留在同一弹窗，新账号提供独立“启用”操作。底部允许切换回调；device_code_unavailable 提示 ChatGPT 安全设置可能需要开启设备码登录。关闭或离开取消流程。备用一次性回调以隐藏输入接受，提交前即清除；流程仅页面内存保留、期限到期或离开页面清除本地信息。远程操作者可在新窗口登录并复制最终 localhost 回调地址，不自动访问操作者的 callback 服务。账号列表不能包含 token；不把订阅授权状态称为可用余额。

CAS/结果不明后锁定变更，成功重新读取才解锁；读取仍失败不能谎报已核对。成功写入后若后续读取失败，同样保持锁定；回调不再显示或提供重发。登录/登出失败给出明确重试，登出未确认也清本页授权信息。前端 API 与 session/CSRF 客户端是实际复用的 shared 模块，不把账号依赖放进 Key feature。


账号界面重新读取先同步当前管理 session/CSRF；其他标签页替换 session 时清除旧 owner 的授权流程，后续写入使用新证明。登出一经发起即清本地账号、CSRF、提示和授权流程；未确认时仅提供重试登出，不允许读列表重新解锁变更。重试重新获取当前证明，401 可确认已退出，其他失败仍保持封闭；不得把请求失败当成 Cookie 已撤销。


## A13：额度、健康与用量诊断界面

主/附加窗口的 allowed/limitReached 即使没有百分比也须显示，缺失明确未提供；额度报告受限与执行健康结论分开。失败查询保留的成功快照须列全日期、Key、模型、模式、错误、状态和仅异常口径，不能让当前表单冒充旧结果的筛选。

账号列表含非秘密 observability 摘要；`GET /api/accounts/:id/observation` 返回有界窗口/健康详情，`POST /:id/observe` 只接受空 JSON 对象，复用 session/CSRF。主次窗口显示真实比例、时长、重置、观察及失败时间；附加标识不猜测模型含义。手动读取失败明确提示并保留上次成功值，不能显示已更新；五分钟陈旧随页面时间推进。认证拒绝与模型冷却分开解释，不展示 namespace/令牌/上游错误正文。额外使用积分只在账号额度详情和手动额度更新的详情响应提供，可选字段 `quota.usageCredits` 包含 `balance`（十进制字符串或 null）和 `unlimited`。详情显示明确的零、上游未提供、不限额和陈旧读数，复用同一观察时间和刷新入口。

`GET /api/usage/options` 与 `/api/usage?start=&end=` 只读且仅管理员可用，复用 A10/A11 的来源/认证和 no-store；不开放给普通 Key。可选 key/model/mode/failure/failedOnly/state/reasoningEffort/outcome/after/limit，拒绝未知/重复参数及非规范游标，最多 100 行；查询繁忙安全 429。DTO 累计用量/估算微单位为十进制字符串或 null，计数/UTC 秒为整数。策略/历史不含正文、图片或凭证。U10 的区间与全时间暴露分别呈现。

管理台采用 hash 路由，访问密钥、订阅账号和用量共享同一管理会话 owner；用量为独立页面，点击某 Key 以 URL 筛选直接进入。仅可读筛选、对象定位 ID 与页码进入 URL，游标、一次性秘密、授权回调和 CSRF 不进入 URL 或持久缓存。用量游标、固定查询窗口和列表滚动位置仅在当前管理会话内存保留，登出或会话更换清除；仅浏览器历史返回（POP）恢复筛选、页码与位置，用量位置按筛选与页码分别记忆；侧栏或链接新进入遵循当前 URL 并从顶部开始，游标失效时明确提示并回到可读取的首页。翻页成功回到列表顶部，Key 客户端每页 50 条。表头随页面滚动吸顶并避开顶栏，不引入双重纵向滚动。创建/编辑以抽屉按需呈现，关键一次性秘密在独立短寿命弹窗中显示。失败读取保留标注的上次成功筛选/快照，旧请求返回不能覆盖新选择；卸载、登出、会话失效清除私有界面。Key 登出开始即隐藏界面并重新取得当前 CSRF 再撤销；未确认只能重试登出，不允许读列表恢复操作。大屏优先实际操作验收。

管理员可从顶栏启用截图隐私模式。首页、列表和详情中的账号和 Key 显示名、主体及相关标识以占位图案显示，相关提示文字和无障碍名称同步遮挡，输入框使用掩码。设置默认关闭，并在当前浏览器标签内记忆。常规交互和管理接口使用原始数据。分享截图时需另行处理浏览器地址栏、开发者工具与已复制的内容。

组件基础使用 Mantine，表单/schema 负责输入和运行时校验；组件库不替代业务授权/结果未知规则。只读Query在会话生命周期内使用内存缓存，不持久化、无自动重试/窗口聚焦重取；秘密返回命令不进入Query mutation cache。会话失效/替换/登出同步退休旧传输代际，并卸载私有视图、取消/清空查询；旧请求401不能撤销新会话。写结果未知的范围锁由会话owner持有，离开页面不能绕过，只有当前owner成功重读相应元数据才能解锁。

保持静态管理资源的严格 CSP，不启用 unsafe-inline/unsafe-eval。主题使用外部CSS，Zod关闭JIT，弹层滚动锁用有owner的外部CSS class代替库的运行时样式标签；焦点/菜单/弹层行为复用组件库。管理响应在原1 MiB/5秒限制内等待最终socket flush完成后关闭，不把已排队当发送完成。

账号治理采用列表→账号详情/一次性授权抽屉：列表分别展示状态、授权和额度摘要，右上角单一“查看详情”入口，启用/禁用统一置于详情设置页，详情承载启停、刷新/重新授权及额度窗口；创建授权成功仍默认禁用。抽屉内保留元数据重新读取入口和失败提示，未知结果不能被关闭/重新打开绕过；详情关闭或账号更换取消只读请求，授权关闭清除回调并按现有一次性丢弃契约处理。

## A14：受控离线摘要导入

管理员批准的Key复用只通过新目标离线导入：私有有界清单、采集时限、整份校验、实例锁、事务全禁用及逐条审计。不得向已有Key/执行/账号/维护历史或恢复态库导入，不支持覆盖、部分提交或自动启用。源停用、任何到期语义或无法表达的策略须隔离，不能静默放宽；与独立管理员验证材料相同拒绝。元数据/输出不含摘要或明文，原字符串认证、显式CAS启用、轮换和持久准入沿用I12。新旧账本与撤销独立，不伪造余额或持续授权同步。离线清单限额同样逐项显式支持 null；源转换 source 模式只在无任何限额记录时推导全 null，有记录则隔离。格式与操作见[摘要导入](../../guide/key-import.md)。

### 管理产品化的兼容增量

`GET /api/usage/options` 保留 `keys`，新增 `keyOptions`（id、可空principal）；`GET /api/usage` 明细新增可空principal、firstEventMilliseconds、totalMilliseconds。`GET /api/usage/keys` 接受可选 includeArchived=true/false（默认 true）；首页传 false，密钥管理保持默认以保留归档 Key 用量与最近使用时间；其他值、重复或未知参数拒绝，返回businessDay={offsetMinutes}、timezone（UTC 或 UTC±HH:00）、startUnixSeconds/endUnixSeconds及keys数组；每项含既有 tokens（十进制字符串）、tokenUsageIncomplete，新增可空 inputTokens/cachedTokens（十进制字符串）、cacheUsageIncomplete，并保留keyID、enabled、可空principal、admitted、succeeded、failed、cancelled、inFlight、pending、可空十进制字符串estimatedMicros、可空lastUsedAtUnixSeconds。口径见 U10；不返回摘要或凭证。沿用管理认证、浏览器来源/会话校验与只读reader容量/超时；容量拒绝429，不接受跨来源浏览器凭证。

## 管理台第二轮 API

所有路径位于现有管理认证/CSRF组，响应 no-store。非法/未知/重复参数400，revision冲突409；查询容量拒绝429，存储/维护门禁沿用现有503。GET参数省略使用缺省值。

| 方法/路径 | 参数 | 返回新增字段 |
|---|---|---|
| GET /api/usage/daily | days=1..31（缺省7）、可选key/model | businessDay={offsetMinutes}、timezone、days、buckets（按日升序）：atUnixSeconds、requests、succeeded、failed、cancelled、failures（类别→次数）、metrics |
| GET /api/usage/in-flight | limit=1..200（缺省200） | rows：id、keyID、principal、displayName、model、mode、accountID、accountDisplayName、startedAtUnixSeconds、elapsedSeconds、hasFirstEvent；按开始时间/id倒序 |
| GET /api/usage | 原有start/end与筛选、limit=1..100、after | totals新增averageFirstEventMilliseconds、p95FirstEventMilliseconds、averageTotalMilliseconds；现有admitted/failed/cancelled/metrics即筛选合计 |
| PUT /api/accounts/:id/display-name | JSON revision、displayName（字符串或null） | account（含displayName与新revision）；账号列表/其他变更返回同字段 |
| PUT /api/keys/:id/display-name | JSON revision、displayName（字符串或null） | key（含可空displayName与新revision）；Key列表/创建/其他变更返回同字段 |
| PUT /api/keys/:id/expiration | JSON revision、expiresAtUnixSeconds（正UTC秒或null） | key（含expiresAtUnixSeconds与新revision）；Key列表/创建/其他变更返回同字段 |

日序列按准入账本计数，不包含可丢弃拒绝诊断；成功/失败/取消/尚无终态分别理解，失败类别包括取消。metrics沿用现有可空十进制字符串（token、图片计数、微美元），不把缺失值记零。首事件耗时不是下游首token；平均/P95按非空样本，P95 nearest-rank。合计不随分页改变。管理界面请求明细每页查询10条，沿用游标翻页。 自定义日期无效时阻止读取并展示日期错误；收起后点击查询须重新展开错误。进行中运行时未知的hasFirstEvent可缺省/为空，历史开始时间缺失同理；前端按未知展示，不推断false。编辑子路径不接受query参数。

## 首页需要处理提醒

`GET /api/attention` 无查询参数，仅管理员可读，复用 A10/A11 的认证、来源、no-store、连接与共享管理容量；GET 不要求 CSRF。返回 `generatedAtUnixSeconds` 与 `items`，最多 50 条，critical 优先，同严重度按 `sinceUnixSeconds` 升序（未知时间最后），再按 kind/主体稳定排序。每项包含 kind、severity（critical/warning）、subjectType（account/key/system/protocol）、可空 subjectID/subjectName、detail、可空 sinceUnixSeconds。detail 包含固定枚举、布尔标记、数值及最多 5 个 Key 的用量排名（仅公开 Key 显示名/主体/ID 和计数），不包含错误正文、头值或凭证。

| kind | 条件 | severity |
|---|---|---|
| account_requires_auth / account_auth_uncertain | 对应账号授权状态 | critical |
| account_cooldown | 当前仍有执行健康冷却 | warning |
| quota_high | 新鲜主/次窗口已用 ≥90%，≥98% 升 critical | warning/critical |
| quota_stale | 观测失败、不可用或超过 U10 新鲜期 | warning |
| key_expiring | 启用 Key 到期时间距当前 ≤7天（含已到期） | warning |
| key_limit_near | 启用 Key 当日请求数或治理预算占用 ≥90% | warning |
| observation_quality | 最近 1h 非客户端取消的未知 ≥10 且占已准入 ≥20% | warning |
| capacity_reference | 今日请求/已观测费用/明细行数达到参考值 80%，超过明确标注 | warning |
| account_concurrency_high | 24h 峰值 ≥每账号 16 的 80% | warning |
| account_rate_surge | 10 分钟 ≥60 且 ≥过去 7 天同时段中位数 5 倍 | warning |
| error_rate_high | 滚动60分钟已准入 ≥20 且失败率 ≥10%，客户端取消不计失败 | critical |
| backup_disabled | 未配置在线备份目录 | warning |
| backup_stale | 最近成功（无成功则本次启用时间）距今严格超过 36h / 72h | warning / critical |
| backup_size | 目录总量严格超过 5 GiB 或单完成 bundle 超过 768 MiB | warning |
| storage_pressure | 现有低盘保护 degraded/blocked | critical |
| client_protocol_extension | 本进程出现未知 WS 控制类型或未知 x-codex-* 头名 | warning |
| attention_source_unavailable | accounts/keys/executions/storage 来源不可读取 | warning |

汇总共享用量只读 reader 的单在途、扫描预算与取消门禁；繁忙返回429，读取失败不能表现为无异常。低盘保护暂停可选读取时跳过统计快照，为 accounts/keys/executions 返回来源不可用项，仍返回存储压力提醒；不绕过可选工作门禁。Key预算占用沿用准入治理，包含未结预留，不是提供者订阅余额。协议名称由入口持有并注入数据与管理入口的并发安全集合记录，最多32个名称，每名称1–128字节可打印ASCII，去重保留首次UTC秒；溢出不再新增并在 detail.overflow 标记，重启清空，不记录值或消息内容。

首页右栏顶部按需展示运行提醒。存储保护、当前接入阻断和已启用备份超时在此展示，未确认的存储状态或提醒读取错误归入右栏底部的数据状态。账号、Key 的个别状态在其管理页面展示，有记录时在首页运行资源下方显示协议观测卡片，按首次观测时间倒序显示概览返回的全部协议记录。名称与首次观测时间复用概览推送和 HTTP 回退。提醒沿用首页刷新与暂停机制。

### 试运行治理操作与账号展示

`POST /api/executions/unknown/release` 复用 A10/A11 管理员认证、来源/CSRF、no-store、请求体和共享管理容量，拒绝 query 参数。JSON 两个必填字段 beforeUnixSeconds、expectedCount 均为非负整数，未知字段拒绝；成功返回 `{ "released": n }`，CAS 不符为 409，容量/存储不可用为 503，所有响应 no-store。事务与证据语义见 U07。

原 unresolved_executions 容量提醒移除。observation_quality 只作质量观察，不能用其非取消计数作人工关闭 CAS。用量与诊断的「提前释放容量」从余量接口读取严格截止前全部 unknown 数；确认未知用量和提前关闭的审计语义。409 及未知结果恢复都重新读取同一个 headroom 来源，不自动重放。

账号读取 accessExpiresAtUnixSeconds 为应用层解密后提取的真实 Unix 秒；未知/取值失败为 null，不传出凭证明文、不改 schema。账号页及首页额度卡显示相对到期时间。15 分钟提前刷新沿用既有授权/额度失败提醒；临近到期本身不冒充刷新失败，无法确定是否刷新时不造失败证据。

账号详情将当前派发状态（账号模式、授权和已知执行健康）与额度观测分开显示。历史请求详情只解释记录中的选路拒绝，缺少候选证据时不以当前账号状态推断当时的排除原因。

全站账号名优先 displayName；未命名统一“未命名账号 · <ID 前 8 位>”。活动、用量与提醒只有 accountID 时使用账号列表映射，找不到也用相同回退；账号页提示可设置名称。


## Key 显示名

Key 显示名与账号共用校验：1—64 个 Unicode 标量、最多 256 UTF-8 字节，拒绝控制、格式、非法字符及行/段分隔符；空字符串非法，null 清除。编辑接口使用 revision CAS，冲突返回 409 revision_conflict；身份、来源、CSRF、容量与审计沿用 Key 修改契约。

displayName 存于现有 managed_keys.metadata_json；旧记录缺字段视为 null，不新增 schema。全量策略更新、到期设置、轮换及恢复禁用均保留显示名。显示名不参与认证、归属、治理或结算，不要求唯一。

所有 Key 管理 DTO、用量 keyOptions、按 Key 今日摘要、用量明细及进行中请求返回可空 displayName，按当前 Key 元数据关联，未知或已删除为 null。attention 的 Key subjectName 优先显示名，缺失回退 principal。界面优先显示名，主体名以次要灰字保留（原生筛选选项以文本并列），搜索同时匹配显示名。编辑抽屉允许留空清除；策略和显示名分两次 CAS 修改，部分成功须提示核对，不自动重放，409 刷新后重新确认。


`GET /api/runtime/storage` 新增 `backup` 对象，复用管理员认证、只读/no-store：enabled、enabledUnixSeconds、lastSuccessUnixSeconds、lastFailureUnixSeconds、lastFailure、lastSkippedUnixSeconds、skippedPressure、retainedCount、totalBytes、largestBundleBytes。未发生的可空时间/分类省略；未启用为 enabled=false、零计数。固定失败分类 directory_unavailable/insufficient_space/snapshot_failed/verification_failed/retention_failed/cancelled，不含原始错误、路径或凭证；成功时间从保留 manifest 恢复，失败/跳过仅在当前进程保留。压力下仍可读健康快照，不增加采样或备份任务。

严格超过 36/72 小时才升级，恰好边界保留前一等级；无成功的宽限从本次启动计时，已有成功则跨重启沿用其时间。备份超时提醒链接存储详情，详情展示最近成功时间，缺失、未启用和尚无成功明确区分，不新增备份页面。体积提醒提示人工容量与异地保存，不自动删旧份。

## 管理台读取与操作展示

未成功读取的账号、Key、请求区块仅展示失败与重试，数量不可用，不显示空态或零；成功空数组才表示无数据。首次失败不声称保留快照；确有成功快照后读取失败才标明保留上次成功快照与时刻。概览多来源失败合并为一条汇总横幅并列出来源，Key 首次失败只在表格内提示并支持重试；翻页失败在分页旁显示错误与目标页重试，保留原成功页。今日 Key 摘要失败/条目缺失的最近使用显示不可用，不推断从未使用。账号策略与授权状态分开着色，需重新授权/授权未知分别使用错误/警告色；长名称安全换行，沿用共享账号名和 KeyName 展示。轮换确认包含 Key 名称、主体、完整可复制 ID 与开关状态。

Key 默认列表排除归档条目；“已归档”筛选通过 archived=true 打开回收站。其他可用状态筛选综合开关和有效期：可用为启用且未到期，即将到期为可用且七天内到期，已到期不论开关，已禁用为未到期且关闭；列表同时展示两个维度，不改变后端独立字段及其他准入限制。到期展示真实 UTC 秒时刻，日期未改保存保留原值；主动改变日期展示原时刻到新 UTC 零点的变化。创建与编辑均允许过去时间，明确警告“保存后立即拒绝新请求”。治理阈值摘要保留最多六位美元小数，非零值不显示为零。匿名首页保留公开运行状态并提供管理员登录入口；登录 429 显示繁忙及等待重试提示，清除提交凭证且不自动重发。

管理员登录入口将焦点送入首个凭证输入框；弹层取消或 Esc 关闭后焦点返回触发控件；提醒定位到 Key 后滚动并聚焦带可读名称的目标行。额度卡片的账号链接直接打开该账号详情，与提醒使用相同 target 参数。绿色仅表示真正可用状态：已到期 Key 的启用开关标签为中性色，账号存在授权异常时系统状态圆点为警告色；用量非状态链接/折叠入口使用主色。

## 治理余量与未知用量

`GET /api/usage/headroom` 无查询参数、管理员只读、no-store，继承 usage 的单在途/1 秒预算/取消/低盘门禁；忙返回 429。返回 generatedAtUnixSeconds、capacities（name/current/limit/blocking；current/limit 为十进制字符串，缺费用 current=null）、accounts（id/current/peak24Hours/limit=16/blocking=true）、storage（既有水位快照）及 storageLimits（stopAvailableBytes/stopWALBytes）。capacities 为 daily_requests、daily_estimated_micros、detail_rows，均 blocking=false；费用是已观测下界，未知部分未计入。账号峰值精确按最近 86400 秒内的准入、释放前及启动恢复样本与当前并发取最大；未配置的参考阈值不返回。样本保留严格递减峰值前沿，新样本覆盖更早的相等/更低值，因此不按请求无限增长。

unknownReconciliation 返回 count、beforeUnixSeconds（两者同快照）、periodSeconds=86400；count 仅 state=unknown 且 created_at_epoch 严格早于截止，人工释放可直接用这一对 CAS 值。余量查询参与首页实时更新与 HTTP 回退。用量与诊断在展开未结执行时读取同一接口，用于确认快照、处理 401、冲突和未知结果核对。存储门禁不开放读取时沿用 `/api/runtime/storage` 展示水位，不将失败读作零。

用量 rows.state 可为 closed_unknown（持久 settled+关闭标记的投影）；totals 与 daily bucket 新增 usageUnknown、unknownReasons（固定失败枚举或 unspecified），区别于待核对 unknown。用量报告 detailRetentionDays=90，详情/小时桶只含保留明细，日序列及 Key 最近使用合并日汇总。quota_high.detail.keyRanking 为最近 5 小时最多 5 个 Key 的已观测费用下界/请求/缺失排名，不代表提供者按 Key 分配余额；原生图片全缺计数的费用仍为未知。

`GET /api/usage/daily` 可选 `end` 为业务日零时的左闭右开结束秒（最多向前 31 日），用于读取已归档日序列；缺省仍含今日。参数无效拒绝，不把日汇总展开为小时。日桶的 recordedRejections 汇总保留期内匹配该业务日及筛选项的准入前诊断，首页单独展示。请求数、失败率与用量沿用已准入统计口径。

## 请求推理强度与服务档位

明细（含首页最近请求所用查询）增加可空 reasoningEffort、serviceTier、actualServiceTier 和布尔 requestMetadataRecorded。来源及有界值规则见 U10 补充；历史及准入前拒绝为 false，各值为 null。筛选 reasoningEffort 接受 `[a-z0-9_-]{1,32}`，精确匹配记录值，排除历史、未指定及准入前拒绝。筛选作用于明细、区间合计、小时桶和缺时间历史计数，既有全时间治理占用不变。

options 增加 defaultReasoningEfforts（模型 ID → 有界默认值），从可信配置 catalog.defaultReasoningEffort 或 upstream.default_reasoning_level 提取，不在线请求上游。明细表新增“推理”列：显式值原样展示，未指定显示灰字“默认”，目录有值时为“默认 · high”等；历史显示“—”。详情显示请求推理强度、请求服务档位和实际服务档位，实际未提供显示“—”。默认值仅为当前目录说明，不推测历史实际参数。

## Key 归档与模型范围

`PUT /api/keys/:id/archive` 和 `/unarchive` 输入严格为 revision，返回 key 和递增 revision。仅停用 Key 可归档（启用中 409 key_enabled），重复归档 409 key_archived，未归档恢复 409 key_not_archived；CAS 失败 409 revision_conflict。archivedAtUnixSeconds 在既有 metadata_json 保存 UTC 秒，缺失/null 为未归档，所有 Key 管理 DTO 返回可空字段。已归档拒绝更新策略/启用/轮换/显示名/到期，409 key_archived；恢复清标记但保持停用。archive/unarchive 审计使用普通容量，不新增撤销预留，不改 schema。归档保留用量、显示名、主体与审计，keyOptions 新增 archived 布尔；Key 类 attention 跳过归档 Key，其他历史用量与账号排名继续关联。界面归档前确认隐藏、统计保留与可恢复；恢复前说明仍停用；启用中归档入口禁用并提示先停用。冲突沿用刷新核对，不自动重放。

创建/更新必须显式提供 models：null 表示跟随全部当前配置对话模型，数组最多32个，[] 保持无对话授权（仅图片 Key）的语义。imageGeneration=true 时 imageModels 可为 null 表示全部配置图片模型；关闭时 null 与 [] 等价，缺失能力字段的关闭语义不变。管理与导入原样返回数组/null，策略版本包含 null。目录、准入、Responses 图片工具及 Images 共用当前配置与权限交集；配置生效后的新增/移除立即影响 null 范围 Key。列表与详情显示“全部模型”。不新增配置热重载。旧二进制不能解码 null 模型范围，回退前须转为显式清单，见[Key治理](../../guide/key-governance.md#兼容回退前提)。

订阅账号池通过 `GET /api/models` 读取生效目录和最近一次发现，`POST /api/accounts/:id/model-candidates` 只读刷新账号候选，`PUT /api/models` 用目录 revision 审核启用或停用模型。发现失败保留最近成功候选；启用发现模型时同时核对所审阅的候选版本，须有完整 profile 和显式费率。生效目录随核心库备份和重启保留。Key options 返回生效对话模型、其支持的档位及目录 revision。Key 创建和更新可附 `catalogRevision`，写入在事务内核对。更新省略 `reasoningEfforts` 保留原限制，显式空对象清除限制。

密钥管理缺省筛选 available，只展示启用且未到期的未归档 Key；显式 all 展示未归档及已归档，客户端并行读取两套既有分页接口、按 ID 去重、任一失败拒绝部分成功；归档和恢复后按当前范围更新列表。

## A18：账号重置卡

所有接口复用 A10/A11 管理认证、精确 Origin/CSRF、共享 16 并发、8 KiB 输入、no-store 与安全错误；数据 Key 无权限，不接受客户端 request ID、owner 或提供者 URL。

| 接口 | 输入与结果 |
| --- | --- |
| GET `/api/accounts/:id/reset-credits` | 无 query；实时 credits（id/type/status/grantedAt/expiresAt/title/description）、availableCount 和 state |
| GET `/:id/reset-credits/state` | 仅本地元数据，提供者不可用仍可核对；revision、settings、pending、pendingCreditID、lastCode、lastAttemptAt |
| POST `/:id/reset-credits/consume` | 空 JSON 或可选非空 creditID；返回 code、windowsReset；不接收客户端幂等 ID |
| PUT `/:id/reset-credits/settings` | revision、autoUseBeforeExpiry、整数 leadMinutes（1—1440）和 retryCount（0—5）；提前分钟数至少为重试次数加 1。兼容只传 leadHours（1—24，转分钟并默认重试 3 次），拒绝与新字段混用；返回本地 state，递增账号 revision |

列表边界与消费屏障见 I21，设置与修订同一 writer 快照读取。GET settings 同时返回 leadMinutes、retryCount 和兼容字段 leadHours（分钟向上取整到小时）。设置成功通知调度 owner 重算。表单用单一提前量输入框配分钟/小时单位选择（总时长1–1440分钟）；整小时默认小时，其他默认分钟，切换单位保留实际时长，保存要求整数分钟，以输入布局展示提前量和重试次数，说明每隔一分钟重试、永不过期后发送及预算须在到期前放得下。消费四个已知结果分别解释“重置成功”“当前没有可重置的用量，卡未消耗”“没有可用的重置卡”“该操作已处理”；unknown 明确结果待确认，只确认核对原操作，不另选卡。卡名与到期时间在确认框显示；管理界面仅提供每张卡自己的使用按钮，不提供由提供者选择的入口。GET 不消费；未知操作禁用新卡使用按钮。列表读取失败保留旧列表并禁用选择，必须重新读取；会话未知结果锁继续按 A13 核对账号，服务端 intent 始终阻止换 ID 重试。

设置显示默认关闭与周期、提前小时范围、无到期卡跳过；设置可在禁用/待重授权账号保存，但自动执行只认 enabled/ready。`reset_credits` attention 链接账号详情，detail.code 为 reset/unknown/repeated_failure，不带提供者原文或请求 ID。

## A19：账号空闲窗口预热设置

GET/PUT `/api/accounts/:id/quota-priming` 继承 A10/A11 管理认证、精确 Origin/CSRF、共享并发、8 KiB、no-store，拒绝 query 和未知/重复字段；普通数据 Key 无权限。GET 返回 revision、settings（enabled、可空/缺省 model、message）、models（当前配置对话模型）、defaultModel、lastAttemptAt、lastResult、attention（均可空）。默认 false/hello，未存 model 时使用 defaultModel。

PUT 严格要求 revision、enabled、model、message，model 必须在当前配置中，消息约束见 I22；无模型无法保存启用，非法输入 400，账号 revision CAS 冲突 409，成功递增修订。设置可在禁用或待重授权账号保存；实际发送重新检查 I22。模型移除和三次失败自动关闭也推进账号修订，不覆盖管理员并发修改；保存设置不解除窗口屏障。

lastResult 为 pending/success/unknown 或固定 ExecutionFailure 分类，结果与 usage 完整度分开理解；unknown 不自动重发。`quota_priming` warning attention 的 detail.code 为 model_removed/repeated_failure，链接账号详情。UI 提供默认关闭开关、配置模型下拉、纯文本编辑和字符计数、最近时间/结果；说明合成流量消耗额度及可能增加风控/账号受限风险，无时间段/推理/输出上限编辑入口。

## 业务日元数据

`/api/usage/options`、`daily`、`keys` 及通用 usage 窗口返回 `businessDay: {offsetMinutes}` 与 `timezone`（UTC 或 UTC±HH:00）。daily 的 end 对齐业务日，通用 usage 仍只接受 UTC 整小时。服务端固定偏移是 UI 日期/日趋势/今日摘要的唯一依据；默认 UTC 仅新增元数据。无定义版本参数或冲突响应；非零设置应与配套 web 一起升级。Key 到期日期输入保持 UTC。

## 相关文档

[文档导航](../../README.md)

首页仅展示当前业务日有准入的未归档托管 Key，无“全部”切换，保留已停用标记。按已观测 Token 降序，缺测排在最后，同量按最近准入秒倒序及 keyID 升序；每次刷新采用完整快照，保留 Key 身份/焦点/详情，失败标陈旧，跨日旧窗口明确标注。六列为 Key、最近活动、请求、失败率（失败数／扣除客户端取消后的已准入数）、Token、缓存命中率。名称后备 principal，内部 legacy-p-* 仅在详情显示；非零执行中在名称旁，取消和结果未明始终可见。结果未明=admitted−succeeded−failed−cancelled−inFlight，不用 pending 推算。

失败率为 failed / (admitted − cancelled)，执行中和未明不计入失败数。扣除取消后至少有 20 条已准入请求、失败至少 5 条且失败率达到 20% 时，强调单元格。失败链接携 Key、摘要起止业务日期及 outcome=failed，点击时不重算今日。outcome 精确筛选只包含已准入且 kind=failed 的执行，排除准入前诊断；与 failedOnly/state/failure 按 AND，failedOnly 原有较宽语义不变。

Token 与限额共用治理投影，部分证据显示已观测下界。缓存率=已观测宿主用量的 SUM(cached)/SUM(input)，无用量请求不进入分母且不使已有率变成 dash；tooltip/详情说明缺失，只有无已观测输入（含输入合计0）为 dash，真实0%保留；原生 Images 不适用宿主缓存。计数/比率用整数与 BigInt 保真，不平均逐请求百分比，拒绝缓存大于输入。单快照分组读取，禁止每 Key 追加统计请求或查询。


大屏首页在右栏显示订阅额度与运行资源，确有需要关注的事项时在右栏顶部显示运行提醒。Key 摘要新增 inFlight（当日 intent 数）；结果未明为 admitted 减 succeeded、failed、cancelled、inFlight，不根据用量 pending 推断结果。

进行中只读投影补充可空 reasoningEffort、requestMetadataRecorded，来自既有 admission 元数据；显式强度原样显示，参数已记录但缺少强度显示未指定，历史未记录显示未记录，不推断实际生效值。卡片展示 Key 别名、模型与推理强度、订阅账号、运行时长及首事件状态；首事件不代表生成完成。

首页明确账号 ID 的详情入口使用首页 account 查询参数就地打开复用的账号详情抽屉，不切换到订阅账号模块；关闭只移除该参数，保持滚动和其他查询字段，刷新/浏览器历史可恢复选择。账号不存在、未启用或读取失败在抽屉中反馈；会话失效清理所选账号。账号操作仍沿用管理授权、CSRF、取消与未知结果约束，变更后刷新首页观测。

账号详情按概览、自动化、设置组织；概览展示已有额度/健康与有界并发快照，缺失不补零。固定标题、关闭入口与页签，仅面板内容滚动。重置卡/预热配置在用户展开时读取，不因进入详情而启用自动操作；同一账号切换页签/折叠保留已加载表单草稿，保存仍按原分区事务与确认处理。版本和UTC等技术信息置于可展开详情。常规字段由分组和列标题说明，避免重复辅助标签；正常额度布尔值不重复展示，未知/受限状态和有后果操作提示仍明确显示。

## 访问密钥展示

列表以密钥身份、概括权限、主要状态、今日用量与最近使用为主，详情底部仅保留创建时间，不重复展示Key ID；模型清单和全部治理限制在详情可查。主要状态优先归档、到期、启用/禁用，临近到期另提示；可用状态不代表绕过权限和额度准入。今日已观测Token与当前Token上限合并展示，费用仅保留在用量统计明细；读取缺失不补零。

列表单一查看详情入口打开连续单页抽屉，依次排列用量概况、名称与权限、使用上限、管理操作及直接展示的密钥信息；固定标题和关闭入口，正文独立滚动；本地治理限额作为固定分组直接展示，不折叠。移除页签及重复的概况卡，用量/模型能力/限制采用卡片分组；保存与管理操作统一在固定底栏，保存按钮关联现有编辑表单，关闭由头部统一完成。用量进度仅表达已观测比例，未知保留下界标识。权限编辑复用原修订、部分成功及未知结果约束；保存成功或需核对时关闭编辑并刷新，校验拒绝保留草稿。归档密钥仍可查看只读策略，恢复后保持停用。到期、轮换、禁用与归档沿用独立确认，创建及一次性凭证流程不变。

Key 配置只包含 tokens（业务日每日Token上限）和active（最大并发），不接受旧请求次数/金额/未结限制字段。单位Token/万Token/百万Token切换保留实际整数数量，保存基础Token数或null，不将旧请求数换算为Token。摘要返回tokens整数字符串与tokenUsageIncomplete，不完整时显示已观测下界。具体准入计量见[用量规范](usage.md)。 持久策略写入同样仅保留tokens/active，schema v11不表示旧五字段二进制可读；不支持原库直接回退，也没有原地降级接口，恢复边界见[Key回退前提](../../guide/key-governance.md#兼容回退前提)。

## A20：首页实时只读概览

首页及首页账号抽屉使用 `GET /api/overview/live`，这是 A10 单响应关闭的精确例外。HTTP 接口继续保留，写操作仍使用 HTTP 与 CSRF。仅接受无 query、无 Bearer、唯一管理 cookie、唯一精确 Origin、合法 Host 与同源 Fetch Metadata 的 upgrade；不协商压缩或子协议，不接受应用入站消息。

v1 envelope 为 `{protocol:1, epoch, sequence, kind, sections}`；kind 为 snapshot/update，sequence 在每连接实际发送时从 1 连续递增。八个 section 为 system、inFlight、daily、keys、accounts、storage、attention、headroom。每源为 `{version, sampledAtUnixSeconds, lastSuccessAt, freshness, code, data}`，freshness 为 fresh/stale/unavailable。data 沿既有 HTTP DTO，inFlight 额外包含 recentlyFinished（兼容旧管理页面的空数组）、overflow 与 clients（Key 显示名、连接数、最早时间）。完整 section 替换；update 中相同内容只发送元数据并省略 data，沿原 version 保留内容、推进 freshness；snapshot 的八个源均须显式含 data（不可用为 null）。来源不构成跨源事务，失败保留旧值，不补零。

准入、首事件及 finalize 成功提交后非阻塞唤醒活动；失败不得影响执行、结算或计量，零 viewer 只做廉价检查。约 100 ms 合并，5 秒 SQL 对账；finalize 标脏聚合并最多每 2 秒重算。storage 2 秒，聚合/system 5 秒，账号/提醒 15 秒顺序采样；最后 viewer 离开取消并 await 查询，零 viewer 不采样。新 viewer 使用共享缓存，重连完整 snapshot，无持久事件或生成回放。

总 WS 8、每 session 2，管理 ingress 总 32；单帧 1 MiB，待发最多 2 条/2 MiB，另 1 MiB 在途，共享缓存/编码 3 MiB。超载/写超时 1013、会话失效 1008、shutdown 1001。15 秒 ping，10 秒 pong/握手、5 秒写期限；关闭握手最多 2 秒，功能整体关闭最多 5 秒。活动订阅每 15 秒沿读取语义延长 idle，不延长绝对 7 天期限。logout/替换/bind 撤销连接，发送前检查有效性。撤销与业务帧发送同一时刻发生时，由连接关闭 owner 在既有截止时间内发送 1008，撤销后不再排队新的业务帧。

首页隐藏、离开或会话代际退役即关闭；有效 snapshot 前保留 HTTP，失败后 15 秒轮询（含 system），三次失败后每 60 秒探测。旧代际结果不能覆盖新数据或解除 mutation 未知锁。2/5/15 秒源超过 6/15/45 秒标陈旧。推送默认开启。页面在收到有效快照后停止定时 HTTP 轮询，连接中断自动恢复轮询并探测重连，立即经 HTTP 核对在途请求，收到新快照前旧卡片暂停计时并标为待确认。实时模式的重试重新建立订阅，HTTP 模式仅重试失败来源。首页在右栏底部汇总异常来源、最后成功时间和重试入口；首次失败明确尚无成功数据，再次读取不重新切回初次加载骨架，已有快照不清空。数字滚动使用本地组件、外部静态 CSS 与浏览器动画 API，固定 240 ms；视觉数位对读屏隐藏，DOM 文本始终为完整真实新值。更换单位/精度/长度、异常大幅变化或上一滚动尚未结束时直接落定新值，不排队。行/条/趋势采用 150—400 ms 连续过渡；首屏、恢复、重新可见直接落定，reduced-motion 禁止位移和滚动，不放宽 CSP。无 schema、恢复、计量变更。交付状态与实际验收见活动任务。

inFlight 首次持久查询失败保持 unavailable/data:null，不以空活动填充；已有快照时内存活动更新不能清除持久查询的失败 code 或推进其 lastSuccessAt，直至实际读取恢复。初始 unavailable 快照结束相应模块的加载状态并明确无成功数据，不伪造空集合。来源明细和各模块共用新鲜度：实时取 section 元数据，HTTP 降级取实际 Query 成功时间/错误，45 秒无成功 HTTP 更新标陈旧；保留旧值不等于已恢复。实时快照的客户端连接统计仅含数据 WS，按 Key 汇总。

首页请求输出速率取已结算请求的速率中位数。每笔以主模型输出 Token 除以端到端请求耗时，包含首输出前的等待。零输出、缺少正耗时、独立图片请求、实际生成图片的对话请求及 SVG 作者输出不计入；仅声明但未调用生图工具的对话仍计入。历史样本恢复时先过滤已记录的生图证据再截取容量。迟到证据确认生图时撤销样本并从账本补位。启动时钟秒及之前（或启动时已有未来时间戳范围内）的样本若已被容量上限淘汰，补位时无法证明它属于本进程，近 60 秒保守不计该样本；小时和日趋势仍按账本补位。首次符合条件的完整结算将速率样本和结算时刻写入同一账本事务，重复结算和证据修订不重复累计。近 60 秒按当前进程内的结算时刻筛选。趋势覆盖含当前小时的最近 168 个小时槽，每小时独立取最近至多 256 笔的速率中位数并显示实际采用的样本数。空小时留空，相邻有样本的小时连线。重启按相同规则从账本恢复小时样本，推送携带业务时区偏移。兼容日聚合继续使用最近 7 个业务日、每日至多最近 4096 笔。启用速率持久化前的请求不回填。inFlight 区段通过可选字段 `recentRequestOutputRateMedian` 和 `requestOutputRateByHour` 推送，兼容字段 `requestOutputRateMediansByDay` 仍提供日聚合。断连、在途快照陈旧、旧版后端和无样本时显示未知。

首页在途区区分首事件未知、等待和已观测。首事件不等于输出完成。结束事件移除在途行并触发用量更新，历史结果由用量与诊断展示。

当前接入条件摘要只汇总本地生成就绪、存储准入、账号资格及账号并发硬限。存在符合资格且有已知并发名额的账号才可显示本地条件正常；全满显示阻断，各项阻断独立判断，来源陈旧时不使用该来源的旧值判定阻断。参考阈值不当作硬限，不承诺具体 Key/模型或下一次上游调用必定成功。

首页今日活跃 Key 表按 Token 排序展示全部活跃 Key，随页面自然展开。Key 摘要通过可空十进制字符串 images 展示当日已观测生图张数，包含原生图片接口与 Responses 图片工具，缺失与零分开。点击 Key 名称进入访问密钥页并打开该 Key 的管理抽屉。没有活跃 Key 时保留面板最小高度。


### 首页运营概览

大屏主栏依次显示今日指标、在途请求和活跃 Key；今日拒绝数大于零时可打开该业务日的准入拒绝汇总与分页明细。右栏依次显示按需出现的运行提醒、订阅额度、请求输出速率趋势和运行资源。整体和各 Key 的失败率分母为已准入数扣除客户端取消数，无符合条件请求时显示未知。生图张数按业务日展示已观测的图片产出，包含原生图片接口与 Responses 图片工具。缺失数据不补零。接入受阻时在运行提醒内显示原因和处理入口。请求卡按开始时间稳定排列，结束后从实时区移除。

运行资源的 CPU 圆环下显示 Linux 的 1 分钟系统负载均值（`/proc/loadavg` 首字段）。该值沿用资源快照和 WebSocket 推送，为可选字段，缺失时省略。

服务器运行资源面板展示数据目录所在文件系统最近一小时的可用空间。磁盘样本与 CPU 和内存按同一周期采集，复用概览推送和 HTTP 回退。缺失样本不补零，无磁盘样本时省略曲线。

订阅额度卡用进度条显示实际已用比例。窗口时长及重置时间可用时，竖线标出该窗口已经过去的时间比例。进度条下方左侧显示距重置的时间，右侧显示本地重置日期和时间。窗口已经到期或数据缺失时省略参考线。

首页各 Codex 额度窗口显示已用百分比，悬停可查看剩余比例。新鲜读数可与时间参考进度比较，差值单位为百分点。进度条支持点击与键盘操作，展开后查看该账号和窗口的实际历史、预测与重置位置。可切换 1、8、24 小时预测参考时段，参考时段长于额度周期时只显示历史。预测只针对订阅窗口，独立于请求 Token 账本、额外积分、重置卡与准入策略。

现有后台额度观察在成功后为 Codex 主、次窗口各记录一个归一化余量读数。每个五分钟时间桶只保留最新读数，最近最多保留 24 小时；接近额度记录大小上限时优先保留较新数据。读数回升、窗口时长变化、周期结束或重置时间偏移超过 60 秒会重新起段。失败保留最后成功记录，过期或失败时暂停预测。历史与当前额度共同写入原有持久化记录，可跨网关重启，无数据库迁移。

`GET /api/accounts/:id/quota-trend` 为管理员按需读取，禁止查询参数并返回 no-store。响应只包含存在历史的 primary、secondary，每个窗口返回 reset（Unix 秒）、duration（秒）和升序 samples（Unix 秒、剩余百分比二元组）。管理首页常规推送与轮询不附带历史。旧记录无历史时返回空对象。

`GET /api/accounts/:id/usage-credit-history?range=24h` 或 `range=7d` 为管理员按需读取，返回 no-store、查询起止秒 `from` 与 `through`，以及按时间排序的 `segments`。每段为 `{at,balance}` 数组，余额用十进制字符串。空历史返回空数组。账号详情概览在「额外使用积分」下展开图表，默认近 24 小时，可切换近 7 天。图表按段画阶梯线，整数轴和读数沿用余额显示口径。

图表保留真实零值，超过 15 分钟的缺口断线，且不计入预测覆盖。覆盖和下降信号充足且缺口两端没有未定位的下降时，对等间隔代表点拟合近期速度，给出到重置前可能耗尽的时间或预计能用到重置。无法完整拟合、但有效观测覆盖至少半个参考时段且可确认累计下降至少 1 个百分点时，可只根据有效观测显示粗估。历史用实线、预测用虚线，阴影为不同消耗速度下的情景。

管理员存储快照（HTTP 和实时）可包含 `resources`，最多 121 个时间戳样本，最近一小时保存在进程内。Linux 每 30 秒采样进程 RSS、主机可用内存、主机总内存和 CPU 使用率（区间内非空闲比例）。首页以环形水位显示主机 CPU 使用率、可用内存和数据盘可用比例，并在下方显示主机 CPU、主机可用内存和网关进程内存的一小时曲线。缺测字段省略，重启清空。数据盘余量和保护状态沿用存储观测，容量已知时同时展示可用比例。
