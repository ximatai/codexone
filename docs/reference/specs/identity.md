# 身份与授权规范

定义账号、主体、Key 和私有引用之间的授权边界。

- I01：principal 必须独立于 Key，Key 轮换保持主体归属；密钥必须高熵、不可逆验证存储，首次显示一次。不得默认跨主体共享对象。
- I02：身份命名空间必须包含可信 origin、协议和稳定提供者身份等隔离维度；改凭证/origin 不得使旧 identity 指向其他实际账号。无法验证身份等价性必须新建并排空旧身份。
- I03：对话模型范围、视觉输入与图片生成必须分别判定；关闭图片生成不得误伤允许的视觉输入。Responses 图片工具和 Images generation/edits 必须共用生成权限。目录、别名和实际执行必须使用相同有效策略。
- I04：每个对外可引用 ID 必须在暴露前事务提交 principal/namespace/identity/type/attempt 归属；绑定失败必须停止暴露且不能换账号重放。未知/过期/歧义引用必须明确拒绝，不得向账号池试探。
- I05：授权必须在新 turn 准入及恢复读取时检查；普通撤销停止新执行，紧急撤销关闭在途并保留结算。模型/工具/池/对象范围不得因旧连接或缓存绕过。
- I06：凭证必须认证加密、版本化且与数据库分离保存主密钥。每身份刷新必须单飞、CAS；旋转令牌 refresh_intent 未完成时重启必须 auth_uncertain，重新验证前不得自动 ready 或循环使用旧令牌。
- I07：管理认证必须与普通 Key 分离，管理 session 必须有安全 cookie、CSRF/Origin 校验与安全初始化。日志不得输出认证材料。

## I08：身份与刷新细则

Provider namespace 包含规范化可信 origin、协议种类、提供者稳定账号、组织/项目等隔离维度；UpstreamIdentity 是不可原地改义的身份。凭证导入/刷新必须通过该适配器可验证的身份声明或身份接口比对命名空间；无法验证等价性时新建 identity、排空旧 identity。不得通过改 origin/project/凭证把 U1 指向 U2 后继续使用旧绑定。管理员对语义变更只能执行“新建并替换”，不是普通编辑；删除用 tombstone 保留账本/绑定历史。

每身份单飞刷新由 Runtime supervisor 拥有，等待者取消不取消共享刷新。刷新采用 credential version CAS，写新密文提交与 refresh_intent 完成标记在同一事务后才发布内存版本。涉及旋转 refresh token 时先写 refresh_intent；若成功响应后的密文提交失败或进程中断，identity 进入 auth_uncertain，停止新 dispatch，不循环重用旧 token。重启必须扫描未完成 refresh_intent，在加载可路由快照之前重建 auth_uncertain，不能因旧密文尚在就自动 ready；除非适配器有经过验证的安全恢复机制，否则需重新授权。单飞与 CAS 不足以恢复丢失的新令牌。

账号状态正交表示 enabled/draining/disabled、ready/refreshing/requires_auth/auth_uncertain、能力、健康与模型 cooldown。先按权限、对象归属、能力、暴露阈值过滤，再用最少在途加稳定打散排序；取得原子执行租约。客户端断连、本地过载/限额不扣账号健康；认证、限流、上游故障分别分类。不能安全重放的失败不进入账号循环。

对象查询为 `(principal, objectType, rawID)` 返回候选命名空间集合；只有一个可用归属才继续。多个候选且与连接/可信上下文约束求交后仍不唯一则 binding_ambiguous；零个为 unknown_or_expired_object，fail-closed，禁止向账号池试探。原始 ID 不全局唯一，首版不改写协议 ID；Key 轮换依赖稳定 principal 保持续接，不默认跨 principal 共享。

首发保留 缓存规范 的短期加密恢复缓存；归属映射本身不能重建上游上下文。缓存缺失、过期、不完整或上游状态丢失时，不能承诺无损续接，必要时由客户端用完整输入/压缩窗口主动新建。不得更改 store 或自动跨账号携带私有对象。[WS 恢复语义](https://developers.openai.com/api/docs/guides/websocket-mode#reconnect-and-recover)

## I09：模型/图片目录与授权细则

创建 Key 时分别配置对话模型允许范围、视觉输入能力与图片生成能力。截图/图片输入属于视觉对话；关闭图片生成不能连带禁止合法模型的视觉输入。图片生成由同一 `image_generation` 权限控制 Responses 内置生成工具与独立 Images generation/edits，各入口调用同一应用层能力判定和资源治理，不能各自实现不一致的开关。客户端 provider 能力声明只用于协商和兼容，不是授权依据。

模型目录按当前 principal 的策略、允许 pool、有效身份能力与模型映射求交，只列至少存在一种有效授权路由的模型，并显示生成能力所需权限；不能展示一个广泛目录再依赖上游拒绝。瞬时 cooldown 属于可用性状态，可保留模型条目但明确暂不可用；授权撤销/能力失效则立即更新目录。模型列表、实际执行、Responses 工具与 Images 映射复用同一能力解析器；模型别名不得绕过允许列表。

## I10：受控单身份运行时注入

单身份功能允许从独立私有文件注入短期访问凭证，不保存或刷新凭证。提供者命名空间绑定可信 origin/协议/身份及当前凭证的不可逆摘要；尚无提供者等价证明时，修改 origin 或凭证须作为新命名空间，不继承旧对象归属。客户端 Key 轮换只改变验证材料及 Key 标识，不改变稳定 principal。进入托管账号/刷新功能后，只有按 I06/I08 验证稳定身份等价的刷新才能保持续接，不能直接用文件替换绕过。

## I11：不透明推理/压缩上下文

提供者返回 reasoning/compaction encrypted_content 时，在暴露前持久绑定“内容类型 + SHA-256 指纹”的 principal/namespace/identity/attempt 归属；核心库只保存指纹和对象 ID，不保存加密正文内容。输入的对应内容必须匹配已有归属，类型变换、篡改、跨主体或身份变化均在发送前拒绝；指纹归属不是提供者仍保有上下文的保证。携完整内容时以正文指纹查归属并移除客户端本地 id，不用标签触发上游私有读取；无 encrypted_content 的 reasoning 仍须校验对象 ID 归属。compaction 需要完整不透明内容，不能只用压缩操作 ID 续接。

## I12：受控上游的托管 Key

显式 managedKeys 模式不接受 legacy Key 回退。Key 创建使用系统随机 256 bit，原文仅在创建/轮换响应显示一次；核心库只存 SHA-256、稳定 principal/Key 标识和版本化权限。普通 Key 不得访问管理命令。轮换保持 Key 标识、主体、计数和归属，只替换验证材料并递增 revision；旧凭证立即失效。策略更新/禁用/轮换使用 revision CAS，不能修改既有 Key 的 principal。

轮换保留当前 enabled 状态，禁用时可以先保存新凭证再显式启用；不得为轮换短暂激活旧凭证。禁用状态的轮换仍使用普通审计容量，不消耗撤销预留。

归档标记在既有 metadata_json 保存可空 archivedAtUnixSeconds，历史缺失为 null，不改 schema。仅停用 Key 可归档；归档后拒绝启用、轮换、策略/显示名/到期修改，须 CAS 恢复且仍停用，再单独启用。归档/恢复分别记录 archive/unarchive 普通审计，不占撤销预留；不删除统计/主体/归属，归档 Key 仍计入容量。认证及持久准入对归档 Key 拒绝，已准入执行照常结算。

每个 HTTP 请求及原生 WS 新 turn 读取当前授权；目录与执行使用 Key 模型范围和受控上游配置的交集，没有路由时目录为空。models 必须显式出现，可为 null（当前配置全部对话模型）或数组，[] 仍无对话授权；imageModels 显式 null 且 imageGeneration=true 时跟随当前全部图片模型，关闭生成时 null 与 [] 等价。缺失能力字段的关闭规则不变。目录、准入、Responses 图片工具与 Images 统一使用有效策略，配置生效后的模型增减立即适用；旧显式策略行为不变。策略版本与导入/管理元数据保留数组/null，回退旧二进制前须转显式清单。持久准入再次检查 Key enabled、revision、principal、模型及限额；Key 五项限额须显式提供正整数（≤10¹²）或 null，null 仅跳过对应 Key 维度，不影响主体/身份/全局限制、账本和未知责任。策略版本包含数值/null 取值；旧授权快照不能在撤销后准入。普通撤销不主动取消已准入执行，既有用量仍结算；紧急撤销的在途关闭另按 I05 实现。显式批准的旧Key摘要仅按A14向新目标离线导入并默认禁用，不构成运行时旧服务认证回退；旧、新撤销不自动同步。此模式不证明已具备账号池、托管上游刷新或恢复读取。

## I13：凭证信封与刷新状态原子命令

凭证信封采用 AES-256-GCM，格式 v1，独立私有文件提供 32 字节随机主密钥（64 个十六进制字符）；key ID 为该密钥 SHA-256 的前 128 bit，仅用于版本选择。每次随机 nonce，AAD 绑定固定用途/格式、key ID、identity、namespace 与 credential version。原文仅为瞬时应用值，不进入公开 DTO/日志；access/refresh/id token 总计最多 32 KiB、单项最多 16 KiB，信封最多 48 KiB。未知格式、非规范 base64、篡改、错误密钥/身份/版本均拒绝。首个实现不提供主密钥原地轮换或丢失后恢复。

账号身份 namespace 不可原地修改且唯一；初次保存已验证凭证时模式为 disabled，授权状态 ready 不等于路由已启用。模式 enabled/draining/disabled 与授权 ready/refreshing/requires_auth/auth_uncertain 分离。刷新开始按管理 revision CAS 持久刷新 intent，随后才可调用上游；结束按 credential version + intent CAS 原子写新密文/版本和 ready，保留刷新期间最新模式。过时/重复完成不能覆盖新凭证或重新启用已禁用账号。提供者身份变化、刷新不明或本地提交失败进入 auth_uncertain，可信端点明确拒绝且未返回新 token 时进入 requires_auth；两者都禁止自动重用旧 refresh token。仅I20所述可信未完成证据可按原intent/version CAS安全结束并保留旧凭证；无法写结束标记时返回本地状态提交失败，已持久 intent 仍禁止自动恢复 ready。重启在同一启动事务内把所有 refreshing 归纳为 auth_uncertain，不能根据未持久的上游结果推测状态。

每库最多 64 个账号；普通账号审计 4096 条，另预留 64 条供非 disabled→disabled 的真实禁用，总上限 4160。开始刷新须同时为开始和一次结束预留审计空间；普通操作、禁用和重启恢复都计入未完成刷新所需空间，不能占掉其结束位置。结束记录走核心 critical 队列。审计保留安全状态快照、revision、动作和 UTC 秒，不保存凭证原文/摘要或信封。没有删除历史或人工恢复 ready 的旁路。

上述原子端口只接受可信适配器验证后的身份/凭证，不是本地 JWT 导入或公开管理接口；提供者验证、Runtime 单飞、账号选择及实际路由接入需各自验收。状态进度见 STATUS，不从密码学或数据库测试推导真实账号可用。

## I14：有界共享刷新 owner

共享刷新由 Runtime Service 拥有，最多 16 个身份工作、64 个等待者、每身份 16 个等待者、4 个并行提供者调用；加入队列前检查容量。同一 identity 和管理 revision 的请求合并，其他 revision 明确冲突。等待者取消只释放自己的等待配额，不取消共享刷新；即使所有等待者离开，Service 仍负责持久完成或 uncertain。未开始的队列不提前写刷新 intent。

单次提供者调用总期限默认 10 秒、配置上限 30 秒；总期限超时取消并 await 网络工作后持久 auth_uncertain，禁止再发同一 token POST。底层提供者必须有自己的 I/O 边界并响应结构化取消；具体 HTTP 适配须另以真实 socket 验证，不能以等待 helper 证明协议关闭。外部错误只返回安全类型，不能透传提供者错误正文或凭证。

优雅关闭先拒绝新等待者和工作，未开始的队列不再消耗令牌；已开始的网络收到 owner 停止信号，取消并 await 后收敛持久责任。已获得可信新凭证时应尽量完成本地提交，不因请求等待者离开丢弃结果。父取消也须等待网络与状态收敛，不留下独立 Task。数据库故障标志在原子开始刷新时复核，已失败的核心存储不能因随后可写就重新开始外部刷新；结束/保守标记仍可使用 critical 配额。

## I15：订阅认证传输的可信来源

首个订阅适配固定 HTTPS 认证 authority 和数据 origin/协议，不提供任意地址或组织/项目头覆盖。专用 AHC client 只用 HTTP/1、每连接一次请求、最多 4 个调用，禁止重定向、连接建立重试、压缩及代理继承；单次请求含正文总期限默认 10 秒、最大 30 秒，响应最多 64 KiB，由 Service 拥有和关闭。测试工厂只允许显式 127.0.0.1 合成端口，认证 realm 进入 namespace，不能借此铸造生产命名空间。

授权码请求使用 form/PKCE，刷新使用独立 JSON 请求；state/nonce 和一次性消费必须由管理授权用例持有。ID/access 只在来自固定 token endpoint 的可信直接响应中解析：校验 issuer、ID audience/当前有效期、subject/account 范围及新 access 有效期；回调兑换另核对本地 nonce，设备码兑换没有本地 nonce，不做 nonce 比对。namespace 包含认证 realm、客户端、数据 origin/协议、subject 和 account。设备码同样依赖固定端点的可信直接传输，不是通用 JWT 签名验证器，禁止用于授权任意上传或本地缓存的 JWT。生产传输使用系统 TLS 验证，合成 HTTP 结果不等于真实订阅验收。

刷新先校验已保存可信 ID 的范围（可过期，仅作身份基线）与命名空间，再请求新 token；新 access 必须证明同一 subject/account，双方有 user 声明时也须一致。新 ID 若提供须校验 audience/当前有效期及相同范围；ID/refresh 字段缺省仅可在新 access 范围已确认后保留原值，显式 null/空字段拒绝。expires_in 如提供须为有效正整数，生效期限取其与 access exp 的较早值。身份缺失/冲突、过期、畸形或网络不明均不能发布 ready。

明确 400/401 且无任何新 token 字段的 invalid_grant，或已识别的 refresh_token_expired/reused/invalidated，返回安全的需要重新授权结果并事务写 requires_auth；其他响应错误/矛盾字段保持 auth_uncertain；建立连接被拒绝、连接建立超时等能够证明未发出token POST的传输失败按I20安全未完成处理，不把读写超时/连接中断当作未完成。服务器错误 prose 不进入日志/DTO，也不用于恢复判断。结束标记提交失败返回存储失败并留下原 intent；重复/过时结束的 CAS 冲突不能冒充存储故障。账号管理流程、具体提供者兼容与池路由另行验收，不能把固定 endpoint 解析或 HTTP 200 作为完整接入证明。

## I16：初次授权流程责任

管理授权流程绑定已认证管理 session 的不透明 owner（独立 headless 管理凭证也有独立 owner）。设备码与回调是同一 owner 的两种流程，共享最多 8 个流程（含创建、在途工作及期限内终态结果）、最多 4 个并行完成；全局容量同时约束每 owner。回调 state/nonce/PKCE verifier 和设备码 device_auth_id 只驻留内存。回调待授权最长 10 分钟，设备码期限取提供者有效期与 15 分钟的较小值，用单调时钟判断。完成调用最长 30 秒，设备码兑换另受流程期限限制。管理员回调输入固定 localhost:1455/auth/callback URL，校验 scheme/host/port/path、state、单个 code，拒绝认证信息、fragment、重复或未知参数；可忽略有界 scope。回调正文、授权码和 verifier 不进入日志或公开 DTO。

设备码创建 POST 固定 issuer 的 /api/accounts/deviceauth/usercode（JSON client_id），404 返回 device_code_unavailable。Runtime Service 的结构化子任务拥有创建、间隔等待、轮询与一次性兑换。POST /api/accounts/deviceauth/token 携带内存 device_auth_id/user_code，间隔取提供者字符串 interval 并夹在 [3,30] 秒；403/404 为 pending；其他状态或畸形响应结束为 failed，不重试。没有任何 HTTP 响应的轮询失败（连接/代理错误或请求超时）不消费授权，下一间隔重试，连续 6 次仍失败才结束为 failed，每次重试写一条仅含错误类型的 info 日志；兑换请求仍不重试。成功响应的 authorization_code/code_challenge/code_verifier 经 PKCE 核对后，只在固定 token endpoint 兑换一次，redirect_uri 固定为 issuer/deviceauth/callback。没有本地 nonce 的信任依据仍是该端点的可信直接传输（I15），不允许上传 JWT。user code 仅在创建响应与本 owner 的 pending 状态读取中显示；device_auth_id 不进入 DTO、日志、审计或存储。终态清除 user code，状态为 pending/completed/failed/expired，completed 带 accountID，failed 带安全 failureCode。记录在原期限内可读取，后续创建可回收已过期的非活动记录。

正确 owner 取得回调流程后，在解析回调及任何 token POST 之前一次性消费；错误 owner 不得消费、读取或取消。容量拒绝不消费尚未派发的回调；设备码成功轮询后若完成容量不足则失败，不再轮询或兑换。失败、过期、请求取消或响应丢失不自动恢复/重放，只能核对账号列表或开始新流程。HTTP 管理连接断开不等于应用任务取消，已接收的操作可继续收尾，须读列表核对。DELETE 取消并等待本流程网络和已开始的提交收敛；Service 停止拒绝新流程、取消并等待所有创建、轮询、兑换和已开始的原子持久操作，不留下后台任务。尚未开始的凭证提交在停止或取消后拒绝。

初次账号生成内部 ID 并以 disabled/ready 保存；明确启用是后续独立管理动作。重新授权绑定 id/revision，保持相同 namespace 和最新 CAS；不能把另一订阅账号原地覆盖，失败不改变原有身份/凭证版本。此契约不授权读取个人缓存或调用真实账号，具体产品入口和真实订阅验收另行记录。


### I16 授权失败诊断

设备码与回调的 failed 流程使用封闭的安全 failureCode：

| 代码 | 含义 |
| --- | --- |
| provider_rejected | 设备码创建/轮询得到非成功、非等待 HTTP 状态（创建 404 除外）；不解析拒绝正文 |
| exchange_failed | 固定 token endpoint 兑换失败，包括拒绝、网络/超时、畸形响应或缺失 token 字段 |
| verification_failed | 设备 PKCE、回调格式/state、nonce 或 JWT 声明校验失败 |
| identity_mismatch | 可信身份 namespace 与重新授权目标不同，或创建时该 namespace 已绑定其他内部账号 |
| revision_conflict | 目标 revision、状态等持久 CAS 条件不满足（身份不同单独分类） |
| device_code_unavailable | 设备码创建端点返回 404 |
| authorization_failed | 未分类错误，包括持久化失败、设备码网络/响应格式不明 |

分类由适配器/用例边界的类型化错误产生，不匹配错误消息，不把 HTTP/数据库框架类型引入 Core。namespace 唯一性在创建事务复核；重新授权先核对 revision/状态，再核对 namespace，并在提交事务再次复核。失败不能改变既有账号、凭证或身份。

Runtime 每个流程首次进入 failed 写一条固定 warning `Account authorization failed`，结构字段仅 method、failure_code、stage（request/poll/exchange/persist，最后进入的步骤）、cause（底层错误的类型名，无负载枚举附 case 名，不超过 80 字符），以及可用时的数字 provider_status；设备码创建失败的两层收尾不能重复记录。provider_status 不进入管理 DTO。不记录 owner、flow ID、提供者账号/邮箱、namespace、URL、user code、device_auth_id、token、授权码/verifier、错误原文或响应正文。expired 不写失败日志；取消/停止仍按既有 owner 责任取消并等待，不新增恢复或重试。


## I17：托管账号 dispatch 的持久复核

Core 凭证准备只产生瞬时 work，不代表已取得执行租约。准备须 ready，enabled 可用于新请求；draining 仅供应用已独立核实对象归属或连接身份固定的续接，disabled 不可用。访问凭证剩余有效期不超过5分钟返回需要刷新，不能把它当成失效刷新令牌或自动改写 requires_auth。

托管 admission 保存非秘密账号快照：管理 revision、credential version、访问期限和可信续接判定；namespace/id 来自既有 owner。快照不从客户端 JSON 构建。SQLite 同一准入事务复核账号 namespace/revision/version、ready、允许模式与当前访问期限，并执行 Key 当前权限和全部资源治理。准备后禁用、刷新或重新授权产生的旧快照拒绝；匹配托管 namespace/id 而省略快照的旧准入路径也拒绝。准入失败不创建 attempt，不可发送生成请求。

普通禁用只阻止新准入，不撤销已提交执行责任，后续绑定/用量结算仍须完成。历史 admission 缺失快照保持可读，不据此推导当前账号授权。凭证、准入和归属查询统一支持至多 512 UTF-8 字节的 namespace，其他持久标识仍按原上限。v4 标记此执行语义，旧二进制须拒绝核心库；该屏障本身不证明账号池排序、续接约束或传输已接入。


## I18：账号池的归属与原子选择

池用例先取得 finalizer ticket，随后准备至多 64 个候选凭证；最多 16 个执行 ticket 覆盖准备、执行与收尾，不建立无限凭证缓存。模型使用明确配置的共同白名单与当前 Key 范围交集。未知模型、无候选、过期 access 不发送生成；刷新及具体协议仍按各自契约接入。

同一 principal 的所有对象引用与可信连接固定身份求交，必须得到唯一托管 namespace/id；单个同名对象可由其他引用或连接消歧，跨主体、空交集和最终歧义均拒绝。SQL 准入事务重新计算交集，避免准备期间新增同名绑定使归属检查过时。continuation 必须与该事务确认的归属或连接身份一致，不由客户端声明。

无归属新请求只取 enabled/ready；有归属可续接 draining，不能迁移到其他账号。事务先排除失效账号快照及已有 16 个活动 intent 的候选，再按当前 intent 数最少、请求 seed 的稳定打散排序，取得唯一执行 intent。显式 Key 限额拒绝只返回一次，不扣账号健康，也不逐账号试探。持久 intent 后，无论本地取消、上游失败或部分用量，只交已有 finalizer；不得选择另一账号重放。

池用例在没有窗口外有效 access 候选时，才按 ID 稳定顺序选一个合格的剩余有效期不超过5分钟/正在刷新身份加入刷新 owner；带归属仅选该身份。单个执行至多一次刷新等待，不因失败切换其他账号刷新。管理入口仍按原 revision 加入；内部路由按 credential version 加入已公布版本的现存工作，因此 begin intent 增加 revision 后仍可共享。尚未公布版本的管理工作仅允许相同原 revision 加入；不同代际或无进程 owner 的 refreshing 状态拒绝，不能重放持久未知 intent。

请求取消移除自己的刷新等待者并释放尚无生成 intent 的执行 ticket，共享刷新仍由 Service 收尾。刷新完成必须重新读取/解密凭证并走同一原子准入，普通禁用、Key 撤销和额度变化不得被刷新结果覆盖。

## I19：订阅数据认证的可信范围

数据认证只接收 Core 从可信密文准备的 work，核对 ID 基线与当前 access 的 subject/account、固定 namespace、快照版本/revision/实际访问期限。ID 基线可以过期，access 不可过期；没有 ID、范围变化或不一致均拒绝。只产生 Bearer 与 chatgpt-account-id，不从下游同名头决定提供者账号，不提供组织/项目覆盖。这是可信保存值的范围复核，不是任意 JWT 的签名验证或上传入口。

生产数据 origin 固定，须匹配生产认证 realm；显式合成目标仅允许 loopback 有效端口并匹配合成 realm。生产凭证/namespace 不允许转发至合成目标，合成凭证也不允许发往生产目标。认证头驻留内存、description/debugDescription 脱敏，不进入编码 DTO、持久库或诊断。

池 readiness 在本地至多逐个检查 64 个候选的当前模式/授权状态与 AEAD 可解密性；不发网络、不缓存明文、不改账号状态。错误主密钥或全部候选解密失败时不得就绪；结构完整但 AEAD 校验失败的单个候选可跳过，其他合格账号仍可派发，关键存储故障仍停止执行。合法可解密的过期 access 可等待已就绪的刷新 owner，不因过期本身变为 requires_auth。


## I20：账号执行健康与被动额度 owner

后台周期扫描遇普通 DB 队列 capacity 时跳过本轮并等待下个周期，不得将可恢复拥塞升格为整个 Runtime 故障；实际存储故障仍停止服务。

执行结果只保留固定失败分类与时间，不能持久化提供者正文/头。可信 HTTP/WS upgrade 的明确 401 阻止当前 credential version 的后续准入，刷新/重新授权的新版本不受旧 401 污染。429 与 5xx 按当前配置模型冷却：单一数字 Retry-After 限 1—3600 秒，缺失/无效分别默认 30/15 秒；重复最终化不延长冷却。不将客户端取消、本地限额/容量、期限或未定位错误计作账号健康故障；额度 GET 的失败也不修改执行健康。无归属新请求可选择其他健康账号，已持久准入和固定连接绝不跨账号重放。

健康是准入事务的必要条件；新托管准入必须显式携模型，历史缺失模型不改写。readiness 要求同一个本地可解密候选与至少一个无当前阻断模型的交集，不能拼接不同候选的资格。配置对话模型最多 32、图片映射最多 16，清理退出配置的冷却作用域；认证版本屏障独立保留。

Runtime 额度 owner 统一手动/周期单飞，最多 64 个账号工作/64 个管理等待者/4 个网络工作，每项总期限 20 秒；HTTP owner 使用独立四容量、5 秒网络总期限和 64 KiB 响应上限，无重定向/重试/代理继承。周期 60 秒处理 enabled/draining 的 ready/refreshing 账号；禁用但有效的凭证仅手动观察，过期禁用凭证须先显式刷新。enabled/draining 且 ready 的访问凭证剩余有效期不超过15分钟（含已过期）时加入已有共享刷新 owner；refreshing 仍加入现有工作，不能建立另一套单飞或旋转语义。dispatch 准备使用5分钟窗口；额度观察仅在真正到期时拒绝旧凭证，不因dispatch窗口拒绝观察。窗口是内部命名常量，不新增用户配置。提前刷新开始/结果日志只含账号id、凭证版本与固定结果分类。

提前刷新中，可信适配器能证明请求未完成（如建立连接超时）且旧access仍有效时，以原intent/version CAS原子结束刷新、清除intent并保持ready，下周期重试；不得用一般网络错误、响应丢失或总期限超时推断未完成。这些不明结果仍按I06/I08/I14进入auth_uncertain，明确拒绝进入requires_auth。安全未完成结束同样走critical队列及预留结束审计，不递增凭证版本，不修改模式/健康。等待者取消只移除等待者；关闭停止接纳、取消并等待所有 owner。记录成功观察须仍是同一 namespace/version/ready，旧返回不能覆盖新授权，失败保留上次成功值。

图片能力要求（路由、视觉输入、公开图片模型）随执行 admission 持久保存，SQLite 同事务复核当前 Key revision 与权限。此语义自 schema v6 引入，当前版本与显式离线迁移/备份见 [O16](operations.md)；历史缺失能力要求的执行仍按纯对话解释。配置与权限细节见[图片配置](../../guide/images.md)和[Key 治理](../../guide/key-governance.md)。

## I16：显示名与Key到期

账号可空显示名是管理员可编辑的持久元数据，1—64 Unicode标量（最多256 UTF-8字节），不含控制/格式/非法字符与换行分隔符；null清除。revision CAS编辑不改凭证版本、授权或路由身份，刷新/重授权/模式变更保留显示名。v9 引入，当前 v11 沿用；显式备份迁移，旧二进制拒绝打开。

托管Key元数据可带expiresAtUnixSeconds；null/历史缺失为永不过期。正UTC整秒，上限10^12，now>=expires时在认证及持久准入屏障拒绝新请求/WS turn，401 api_key_expired，不建立执行记录；已派发仍正常结算。管理员可通过revision CAS设置、延长、清除，轮换/策略变更保留到期时间。到期不删除密钥或账本，不重置用量。

Key 可空 displayName 使用与账号相同的校验，存入既有 Key 元数据 JSON，缺字段为 null；CAS 编辑并审计，不改 schema。显示名可重复，不作为认证、归属或结算标识。轮换、权限/到期更新保留显示名，主体标识仍不可修改。

对象绑定的 30 天续接期、迁移宽限、成功准入续期与小批到期删除见 U14；到期引用仍 fail-closed，不向其他账号试探。每账号并发 16 是保护账号流量形态的阻断项，超出可重试 429，unknown 不占活动并发；24 小时峰值和速率突增仅用于提醒。

## I21：重置卡消费的持久幂等与到期 owner

重置卡 list/consume 使用 I19 的同一可信身份、头、固定 host 与显式代理，复用 I20 独立配额 HTTP client 四容量、5 秒期限、64 KiB、无重定向/自动重试。列表最多 128 张，标识最多 256 字节、类型/状态各 64、标题 512、描述 2048；时间为 RFC 3339，未知类型/状态保留为有界展示值，自动选择仅认 available。正文不持久化。quota 仅额外保存可空 availableResetCredits 计数（0—128），不作为授权或余额真相。

每账号最多一个未完成 intent（服务生成 UUID redeem_request_id、可选 creditID、来源标记），发送前与审计占位同事务提交。每次网络消费占一个独立审计行（最多 4096），结果回写预留行，结束走 critical 队列，不消耗账号刷新/禁用预留；满时发送前拒绝。reset/nothing_to_reset/no_credit/already_redeemed 为终态，其他代码、断流、超时、取消和本地结果提交失败保留原 ID。下一次同卡或默认核对沿用原请求/卡；其他卡冲突，不产生新 ID。未知代码归 unknown，不记录原文。

Runtime ResetCreditSupervisor 是自动周期与手动工作共同 owner，每账号一个工作、总共最多四个，无待执行修改队列。自动设置默认关闭，leadMinutes 为整数 1—10080（默认 1440），retryCount 为额外重试次数 0—5（默认 3），固定 retryIntervalMinutes=1；leadMinutes 至少为 retryCount * retryIntervalMinutes + 1，按账号 revision CAS 保存。设置仍在 account_reset_credits.record_json（4096 字节上限），不升级 schema；只有 leadHours 的旧记录按小时乘 60、重试默认 3 解码。新记录同时写 leadHours=clamp(ceil(leadMinutes/60),1,168)，v0.26.4 可读取回退，但回退后只有整小时/30 分钟周期行为，没有分钟调度与本次重试保证。

每 30 分钟读取列表学习最多 64 个账号的到期时间；观察快照的可用卡计数可触发 64 条有界提示，仍受常规周期门槛，设置修订变化例外，立即重算。仅 enabled/ready 且已开启自动使用的账号参与；手动未知 intent 只人工确认核对。Runtime 每账号只保留一个最早 available 卡的 expiresAt - leadMinutes 到期时间和一个有界重试状态，一个结构化定时任务等待最近到期/重试/常规周期（最长一分钟），到点优先处理已学习的截止时间。扫描最多四个结构化工作并共享手动容量门禁；容量可用且 I/O 正常时，在到点后约一分钟内开始，容量占用时不排无限队列。每次列表/设置变化重算；不持久化列表、定时器或重试队列，重启首次扫描重建，已过阈值但未过期立即尝试。

新自动消费必须重新读取列表，选择 now < expiresAt <= now + leadMinutes 的 available 卡，最早到期、同时间按 id，每账号每轮最多一张；永不选择无到期卡，在凭证准备、持久 intent 提交后发送前再次检查，now >= expiresAt 不发送。自动未知 intent 优先沿原 ID/原卡核对，以新列表更新原卡到期时间；已被标记使用或在丢响应后消失的原卡可沿同一 ID 核对，但必须有新列表或本次 Runtime 已学习的原卡到期时间，且仍在未来，绝不换卡或新 ID。重启后原卡不在列表且无法重建到期时间时不自动发送，保留人工核对。扫描中账号被删除或修改只跳过该账号，仅存储不可用停止 Runtime。

自动列表失败、网络错误/超时、提供者 5xx、unknown/丢响应至多进行初次加 retryCount 次尝试；失败后至少一分钟再试，有已知到期时间时仅安排 retryAt < expiresAt 的重试，并在实际发送前复核。首次列表失败尚无到期信息时只重试读取，读取成功确认到期后才可能消费。每次失败列表/网络消费继续写独立有界审计；消费失败与中途列表失败共同占用预算。未知 intent 的失败计数跨重启保留，预算耗尽后保留人工核对屏障，不自动创建新 ID。reset/already_redeemed/no_credit 停止重试；nothing_to_reset 结束 intent，卡未消耗，不扣失败预算，在下个常规周期可再试。手动使用不自动重试。

自动明确返回 reset 保留 24 小时提醒；already_redeemed 只表示原操作已处理，不推断实际重置窗口或卡消耗。未知 intent 持续 critical 提醒，初次加配置重试预算均失败后显示 repeated_failure 及实际失败尝试次数；手动未知仍保留原三次失败提醒阈值。审计仅固定动作/结果、账号 ID、卡 SHA-256、来源与时间；日志只账号 ID、卡摘要/默认标记、固定结果和尝试序号，不输出标题/正文/身份头。停服拒绝新工作，取消并 await 定时器、网络及 critical 收尾，未确认 intent 跨重启保留；恢复自动关闭见 O16。此能力不代表官方客户端菜单透传或按用量压力自动使用。

## I22：空闲配额窗口预热

每账号默认关闭，消息默认 hello（1—200 Unicode 标量，拒绝控制/格式/非法及行段分隔字符），按纯文本发送。模型仅取当前配置对话模型；默认按输入与输出本地费率之和最低、同价按 ID 排序。保存和发送都复核配置；已选模型移除时持久关闭、递增账号修订并发出 model_removed 提醒，不自动换模型。

只检查 wham/usage 的 codex 主配额，窗口时长必须明确为 18000 或 604800 秒。idle 要求 used_percent=0、reset_after_seconds 等于完整时长、reset_at 与观察时刻加时长差不超过 5 秒；allowed=false、limit_reached=true、缺失、重复时长、矛盾或未知字段都不触发。观察须成功且满足 U10 的 300 秒新鲜期。0% 可能经过取整，此判定仍是保守推断，尚无真实订阅验收；无 reset 字段不视为未启动。任一已知窗口 idle 可触发一次请求，两个 idle 仍只发一次。

同一正常准入事务保存每窗口最近尝试时刻、观察 reset_at、等待活跃屏障，并写独立审计占位和执行 intent；之后的空闲 reset_at 移动不算新窗口。任何已尝试窗口仍等待活跃时，整个账号都不再发送。必须有晚于尝试的新鲜成功观察证明对应窗口活跃（有未来 reset_at，已用大于零或剩余时间小于完整时长减 60 秒，reset_after 如存在须一致），并等该活跃 reset_at 到期，才允许后续预热；每窗口至少间隔一小时。确定未被提供者接受的失败（非超时、取消、无效上游响应或 indeterminate）解除对应窗口屏障；成功后尝试 900 秒以上的新鲜观察仍为空闲时解除屏障并记 not_started 失败；只有观察到窗口活跃才清零失败计数。重启保留屏障和 unknown，绝不重放预热。连续三次失败/未知/not_started 自动关闭（账号修订递增）并提醒 repeated_failure；管理员保存可清除停止原因和失败计数，不能清除窗口屏障。

仅 enabled/ready、凭证有效、无认证阻止或所选模型 cooldown、账号并发低于 16、可选存储门禁开放才准入。内部 principal/key 标签 internal:quota-priming 没有凭证，不属于客户端 Key；mode=priming。复用执行协调器、账号快照/健康/并发检查、订阅身份头、配置指纹/显式代理、正常 Responses HTTP/WS、用量证据与 finalizer，不选池或跨账号重试。tools=[]、无图片/引用、store=false；固定最短回答指令、提供者目录未明确不支持时的低 verbosity、目录声明的最低推理档位（无声明采用 low）。订阅契约不支持 max_output_tokens，故不发送，不能承诺一个 token 的硬上限。输出仅丢弃，不进入正文历史。

Runtime 单顺序 worker、64 条有界观察提示与 60 秒扫描，最多一个在途生成；20 秒总期限，关闭停止接纳、取消并 await 子任务和 I/O，finalizer 继续承担结算。独立审计最多 4096 条，包含账号、窗口种类、模型、时间和固定结果分类，先占位 pending、原位完成；启动未完成者归 unknown，不存消息/输出。容量满跳过发送。schema v11 与重置卡同次未发布迁移新增状态/审计表；备份保留屏障，恢复强制关闭自动预热并保留 unknown，不借恢复清除已执行风险。

## 相关文档

[文档导航](../../README.md)
