# 身份与授权规范

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

单身份切片允许从独立私有文件注入短期访问凭证，不保存或刷新凭证。提供者命名空间绑定可信 origin/协议/身份及当前凭证的不可逆摘要；尚无提供者等价证明时，修改 origin 或凭证须作为新命名空间，不继承旧对象归属。客户端 Key 轮换只改变验证材料及 Key 标识，不改变稳定 principal。进入托管账号/刷新切片后，只有按 I06/I08 验证稳定身份等价的刷新才能保持续接，不能直接用文件替换绕过。

## I11：不透明推理/压缩上下文

提供者返回 reasoning/compaction encrypted_content 时，在暴露前持久绑定“内容类型 + SHA-256 指纹”的 principal/namespace/identity/attempt 归属；核心库只保存指纹和对象 ID，不保存加密正文内容。输入的对应内容必须匹配已有归属，类型变换、篡改、跨主体或身份变化均在发送前拒绝；指纹归属不是提供者仍保有上下文的保证。携完整内容时以正文指纹查归属并移除客户端本地 id，不用标签触发上游私有读取；无 encrypted_content 的 reasoning 仍须校验对象 ID 归属。compaction 需要完整不透明内容，不能只用压缩操作 ID 续接。

## I12：受控上游的托管 Key

显式 managedKeys 模式不接受 legacy Key 回退。Key 创建使用系统随机 256 bit，原文仅在创建/轮换响应显示一次；核心库只存 SHA-256、稳定 principal/Key 标识和版本化权限。普通 Key 不得访问管理命令。轮换保持 Key 标识、主体、计数和归属，只替换验证材料并递增 revision；旧凭证立即失效。策略更新/禁用/轮换使用 revision CAS，不能修改既有 Key 的 principal。

轮换保留当前 enabled 状态，禁用时可以先保存新凭证再显式启用；不得为轮换短暂激活旧凭证。禁用状态的轮换仍使用普通审计容量，不消耗撤销预留。

每个 HTTP 请求及原生 WS 新 turn 读取当前授权；目录与执行使用 Key 模型范围和受控上游配置的交集，没有路由时目录为空。持久准入再次检查 Key enabled、revision、principal、模型及限额；旧授权快照不能在撤销后准入。普通撤销不主动取消已准入执行，既有用量仍结算；紧急撤销的在途关闭另按 I05 实现。此模式不证明已具备账号池、托管上游刷新或恢复读取。

## I13：凭证信封与刷新状态原子命令

凭证信封采用 AES-256-GCM，格式 v1，独立私有文件提供 32 字节随机主密钥（64 个十六进制字符）；key ID 为该密钥 SHA-256 的前 128 bit，仅用于版本选择。每次随机 nonce，AAD 绑定固定用途/格式、key ID、identity、namespace 与 credential version。原文仅为瞬时应用值，不进入公开 DTO/日志；access/refresh/id token 总计最多 32 KiB、单项最多 16 KiB，信封最多 48 KiB。未知格式、非规范 base64、篡改、错误密钥/身份/版本均拒绝。首个实现不提供主密钥原地轮换或丢失后恢复。

账号身份 namespace 不可原地修改且唯一；初次保存已验证凭证时模式为 disabled，授权状态 ready 不等于路由已启用。模式 enabled/draining/disabled 与授权 ready/refreshing/requires_auth/auth_uncertain 分离。刷新开始按管理 revision CAS 持久刷新 intent，随后才可调用上游；结束按 credential version + intent CAS 原子写新密文/版本和 ready，保留刷新期间最新模式。过时/重复完成不能覆盖新凭证或重新启用已禁用账号。提供者身份变化、刷新不明或本地提交失败进入 auth_uncertain；无法写标记时已持久 intent 仍禁止自动恢复 ready。重启在同一启动事务内把所有 refreshing 归纳为 auth_uncertain，不能自动重用旧 refresh token。

每库最多 64 个账号；普通账号审计 4096 条，另预留 64 条供非 disabled→disabled 的真实禁用，总上限 4160。开始刷新须同时为开始和一次结束预留审计空间；普通操作、禁用和重启恢复都计入未完成刷新所需空间，不能占掉其结束位置。结束记录走核心 critical 队列。审计保留安全状态快照、revision、动作和 UTC 秒，不保存凭证原文/摘要或信封。没有删除历史或人工恢复 ready 的旁路。

上述原子端口只接受可信适配器验证后的身份/凭证，不是本地 JWT 导入或公开管理接口；提供者验证、Runtime 单飞、账号选择及实际路由接入需各自验收。状态进度见 STATUS，不从密码学或数据库测试推导真实账号可用。
