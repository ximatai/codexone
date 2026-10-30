# 协议与执行规范

- P01：网关必须经统一数据入口支持选定 Codex 客户端契约的 HTTP JSON/SSE、WS Responses 及独立 Images generation/edits；端点/别名/斜杠/错误 envelope 必须有显式契约测试，不能任意后缀转发。
- P02：允许组合必须按后端、客户端版本、端点、传输、模式、工具记录；background 及未支持控制/对象服务必须在 dispatch 前拒绝。warmup 与 compact 只有独立生命周期契约验证后开放，不得默认禁用核心客户端依赖再宣称兼容。
- P03：WS 必须先本地认证，再由首个有效 create 串行完成身份绑定；连接期间不得更换上游身份。后续 lane 必须符合该身份及当前授权；同 lane FIFO，跨 lane 总容量有限。
- P04：每个上游 WS 必须单 reader、串行 writer，控制分片/聚合大小、队列字节及条目，入口须在创建任务或入 actor mailbox 前取得容量。整连接拥塞必须有期限/关闭及每 turn 最终化路径。
- P05：所有任务、连接、continuation 必须有可验证的 owner、单次结束和取消/await 路径；下游静默断连也必须触发本地资源回收。关闭本地 socket 不得被表示为上游已停止执行或收费。
- P06：已可能发送/执行的请求不得透明重放。只有明确未执行证据才允许有界重试；固定归属的引用不得跨账号。EOF 不等于可信终态，错误不得伪装成功。
- P07：上游凭证必须由服务注入，剥离下游声明/凭证；actor 能力声明不得充当授权。服务器不得逐请求启动 Codex CLI，CLI 只能为外部测试客户端。
- P08：HTTP 请求/响应、SSE 事件、WS 帧/聚合、multipart、解压大小必须有公开硬限制；慢消费者、首消息、建连、首包、进展和总期限必须可分类诊断。

## P09：端点与执行模式

发布清单按“后端 × 客户端版本 × 端点 × 传输 × 执行模式”列验证组合。网关只对自身职责执行允许列表：认证与 Key/模型/视觉/图片权限、大小/期限/并发、能读取提供者存储状态的引用归属、执行模式控制、账本与可信用量。其他请求字段、input 条目、内容 part 及工具声明原样转发，由提供者判定；见 [P27 开放协议透传](#p27开放协议透传)。

| 能力 | 首版策略 |
|---|---|
| HTTP `POST /v1/responses` | foreground、普通 JSON/SSE；`background=true` 明确 400，不改写为 false |
| WS `/v1/responses` | `response.create`，default/named lane；同 lane FIFO、跨 lane 受控并行；整个连接同上游身份 |
| WS `generate:false` | 首版 Desktop 预热契约必验；单独 warmup 状态机，经适配器声明及验证后开放，不作为普通生成统计 |
| 文本与客户端 function tools | 支持所选 Codex 契约；网关不执行用户函数/CLI；每次客户端提交工具结果是新 turn |
| 图片输入/Responses image tool | 分别授权、限制和计量；仅开放已验证的模型与参数组合 |
| 独立 Images generation | 首版必含 `/images/generations`，兼容配置只增加经验证路径别名，不做任意后缀转发 |
| compact | 首版 Desktop 压缩契约必验，作为单独前台模式实现；输出先分类，含私有引用需绑定；其他未支持的后端明确拒绝 |
| 独立 Images edits | 首版支持已验证 Desktop 的参考图编辑；输入格式/图片与 mask 组合、参数和返回/流式事件列入契约，不能泛化为全部 Images 功能 |
| conversation、prompt 等服务端存储状态 | 无法证明归属，dispatch 前 400；web_search、tool_search、远端 MCP 等由提供者执行的工具声明透传，费用计入所用账号，不由网关执行 |
| 后台任务、steering、未实现的取消/控制事件 | 首版拒绝；只允许经过契约验证的 turn 级取消，否则采用连接级关闭策略 |
| GET/delete/cancel response | 不承诺公共对象服务；仅适配器拥有且不暴露给客户的核对接口可内部使用 |

扩展字段与未知事件不授予对象归属、用量或终态权，按原样转发给客户端。执行控制只认已知模式控制（generate、compaction_trigger、background），对象归属只来自 P27 定义的证据。

## P10：重试、超时与外部错误

默认无输出也不等于可重试。未发送请求可有限重选；适配器明确证明未执行的拒绝可按总 deadline/attempt 预算重试；已发送后断线/超时、已返回 ID 或语义输出一律不透明重放。跨账号还需全部引用无归属冲突且主体允许。旧凭证 401 只有明确拒绝未执行时，单飞刷新后最多重试一次；429 尊重 Retry-After，固定谱系不跨账号。一次重试有独立 attempt 和上游成本记录。

排队、连接/TLS、响应头、首语义事件、活跃进展、下游写、总 turn 和连接寿命分别限时。NIO channel close 即使上游静默也必须触发下游取消；图片/思考可有较长 idle 策略，但不延长慢消费者期限。单调时钟用于 deadline，UTC 用于账期。

网关错误保持协议 envelope、稳定 code、脱敏信息与 request ID；区分权限、quota、capacity、unknown/ambiguous binding、上游状态丢失、授权需要更新、client_too_slow、execution_indeterminate。提供者错误按 P27 脱敏透传其可操作成员。HTTP 提交前可回 4xx/429/502/503/504；提交后提供者失败以 response.failed 事件、网关失败以 error 事件结束。WS 握手后不可返回 HTTP 状态响应；error 帧携带 status，lane 错误服从执行生命周期规范的 FIFO。认证升级后的首条create解析失败时，先尽力发送标准error帧再关闭连接，不回显未验证lane，不建立上游或创建执行；发送失败仍关闭，不自动重放。失败不伪装成功、EOF 不视为终态。

## P11：Desktop 与现有接入兼容

首版必须以明确版本的 Codex Desktop 为主要真实客户端，CLI 为补充；允许清单必须覆盖实际使用的模型选择/目录、HTTP JSON/SSE、WS、连接预热、压缩、工具结果提交和续接。仅 CLI 成功不得表示 Desktop 通过；warmup/compact 不得在首版替代验收中整体标为可选而跳过。具体模型、参数与客户端版本由验收矩阵声明，未验证组合明确拒绝。

必须验证标准 `/v1` 入口与现有 `/backend-api/codex` 前缀下的 responses（HTTP/WS）、models、responses/compact、images/generations 和 images/edits 等价路径，记录斜杠、认证、错误及模型元数据行为；不要求复制无关旧 API。HTTP 下游直连 HTTP 上游、HTTP 下游桥接 WS 上游及原生 WS 路径均须有外部行为验证。实现可复用或替换旧桥接设计，但不得因连接复用改变身份、重试与结算约束，也不得通过客户端全量改成另一传输来跳过验收。能力协商头只能表示能力，不得替代本地 Key 授权。

## P12：有边界的图片生成与编辑

Images generation/edits 是独立原生产品入口，直接请求所选身份的 /backend-api/codex/images/*，不经 Responses 图片工具改写。必须明确透传、图片模型授权、错误 envelope、用量与终态含义，不能依赖对话模型名称推导图片权限。Responses 托管图片工具保持独立能力与计量契约。

edits 必须支持已验证 Desktop 参考图编辑契约所需的图片输入（含适用的 multipart）、返回格式及流式行为；图片数量、类型、解码尺寸、multipart/掩码与输出均有界；提供者参数组合交由原生端点判定。直接提交的图片数据无需先开通公共文件上传/读取；不得默认抓取任意远端 URL。编辑与生成复用图片能力判定和执行治理，视觉输入仍单独判定。含图历史及图片工具可与 compact、流式压缩组合，权限不放宽。Responses 图片工具要求图片模型在 Key 有效 imageModels 中、对话模型已授权且配置 imageGeneration: true；Images 直接使用公开图片模型调用原生端点，hostModel 仅为无效兼容字段。客户端对已完成编辑主动发出下一次编辑属于新执行；网关不得将断线恢复自动变为重新编辑。

## P13：受控单身份 HTTP 配置契约

单身份 Key 先验证，再由应用层按模型与每个硬引用的主体/命名空间/身份判定准入。模型目录仅列可信配置允许的模型。`/v1` 与 `/backend-api/codex` 的显式 HTTP 路由共用同一授权和执行用例，不做任意后缀匹配；尾斜杠未定义时明确拒绝。HTTP 请求以 `application/json` 输入，不接受压缩请求体；字段、工具与对象类型按 P27 透传。

请求体为 32 MiB（与下游传输聚合一致）、JSON 深度 64、硬引用 32；input 条目与工具声明数量只受总字节约束。普通 Responses 上游 JSON 与累计流 32 MiB，单 SSE 事件/WS 帧 8 MiB。连接最多 8，入站异步通道高/低水位为 4/1，单次接收分配最大 64 KiB；请求读取 10 秒、上游建连 5 秒；单次执行总期限默认600秒（可信配置1—1800秒），首响应默认30秒（1—120秒）、有效进度空闲默认60秒（1—300秒），显式阶段期限不能超过总期限，省略时取总期限的较小值。阶段计时由独立owner覆盖HTTP/WS/compact，SSE注释、ping/pong、重复created/in_progress和空delta不续期；JSON正文按非空负载字节推进，仍受总期限和大小约束。底层HTTP读取使用较长保护期限，不抢先替代阶段错误；发送至消费/绑定/输出始终在单调总期限内，下游写入 5 秒超时关闭连接。后续图片使用独立验证过的负载边界，不沿用文本限制冒充图片能力。

归属持久屏障在每个含对象的上游事件写下游之前完成；先确认终态属于当前执行，再观察可信用量，随后做对象绑定/输出。HTTP SSE的生命周期事件 response.id 及任何 response_id 必须与本执行首次出现的 response ID 一致，不从外来终态获取计量证据；稀疏HTTP流不额外要求先created。上游 EOF、无终态或缺失用量不得伪造成成功/零消耗。部分证据的计数只表示已观察下界，完整度为 partial，继续保留未知暴露。发生核心持久故障后停止后续发送，数据/管理 readiness 反映不可用，liveness 不作为账号额度判断。

配置与文件安全说明见 [单身份配置](../development/single-identity.md)。Desktop、WS、预热、压缩的最终兼容验收仍按 P11，不能从 HTTP 合成结果推导。

## P14：单身份 WS 连接与 lane

配置 websocket 上游后，原生 WS 与 HTTP→WS 桥接复用相同持久准入/屏障/用量用例。握手只本地授权/容量管理，首个有效 create 才建立固定身份 socket；同 lane 串行 FIFO、跨 lane 可并行，不重连重放。stream_id 为 1—256 字节 ASCII 字母/数字/下划线/点/连字符，最多 32 个命名 lane（另含默认 lane），最多 16 个在途 turn；超限终止连接，已 dispatch 执行按原证据最终化。generate:false 使用独立 warmup 模式，仍占准入与未知暴露，不假设免费；只允许无生成内容的响应生命周期事件。未支持控制明确拒绝；真实客户端仍按 P11/E10 验收，不从合成 WS 切片推导完整客户端支持。

下游 WS 消息/分片聚合为 32 MiB，单上游事件 8 MiB、累计执行 32 MiB；上游 peer 入站队列为 64 条/8 MiB，下游入站及原生请求调度队列各为 64 条/48 MiB，超过 8 MiB 正文另受共享预算约束，每 lane 最多排队 4 条，另持有一个有界 producer 消息；至多 33 个 lane worker，各自最多处理一个有界命令，5 秒拥塞终止连接；单 reader、串行 writer，校验 mask 角色/RSV/UTF-8，控制帧由帧读取层校验并本地处理 ping/pong。首 create 10 秒、后续请求仅在无执行/排队turn时计120秒空闲、连接寿命最多1小时；执行使用 P13 总期限，慢下游写 5 秒关闭。关闭 owner 覆盖未完成握手及已连接 socket，取消并等待子任务，不等待结算形成循环。

HTTP 桥接每执行新建上游 socket，不保证跨请求 store=false 连接缓存；原生 WS 续接使用原 socket。上游 reader 只校验生命周期归属：turn 的第一个生命周期事件确定 response ID，此后生命周期事件与 response_id 必须一致，否则关闭连接；连接内最近 1024 个已开始的 response ID 不能开始新 turn。turn 外事件（如额度通知）及新 turn 开始前属于旧 turn 的 response.* 输出被丢弃，不进入下一 attempt。提供者 error 事件结束当前 turn，以带 status 的 error 帧下发，连接保持可用；终态通过已准入 attempt 注册的同步证据 sink 观察用量，其他 lane 失败不得清除已接收的可信用量。终态与 EOF 同到时，消费已进入有界队列的事件后再报告 EOF；已观察用量不因网络关闭丢弃。连接关闭不证明上游未执行，未观察终态保持 unknown。

下游 WebSocket 扩展提议可以存在，网关忽略提议且不返回扩展协商头；没有实现压缩，不接受未协商 RSV 帧。不能因客户端提供可选压缩提议而拒绝整个握手并将 HTTP fallback 误算为原生 WS 成功。未支持的子协议仍拒绝。实际客户端检查须分别证明直连、桥接与原生连接行为，而非仅最终回答成功。

## P15：客户端上下文与前台模式

完整 inline 消息、function/custom tool 结果、additional_tools 包及携完整 encrypted_content 的 reasoning/compaction 中的 id 为客户端本地关联标签，发送上游前移除。只有能让提供者读取存储状态的引用是硬引用：previous_response_id、item_reference、仅凭 ID 指向的 image_generation_call（无 result）与 reasoning（无 encrypted_content）；它们必须已绑定到当前主体/身份，否则 dispatch 前拒绝。call_id、加密上下文指纹和其他条目 ID 是路由提示（最近 64 个）：账号池中已知时优先选择其账号，未知或属于他人时忽略，不拒绝也不建立读取权。加密内容只能由签发它的上游账号解密，跨账号时由提供者拒绝。

WS generate:false 为 warmup，普通 HTTP 不接受 generate 控制；预热只返回无生成内容的 response.created/in_progress/终态，不能伪装普通生成或默认记零。独立 HTTP POST /responses/compact 为 compact 模式，两个前缀共用授权/限额/屏障；即使生成走 WS，compact 仍走同可信 origin 的 HTTP 显式端点。返回 response.compaction 的完整 output 窗口不裁剪、不改写，不把 compaction ID 当 previous_response_id；窗口内对象先作为本执行的路由证据幂等绑定，再整体返回。压缩请求沿 32 MiB 请求、32 MiB 响应、总期限及失败语义；未支持模式/输入不发送。

reasoning、text、stream_options、include、tool_choice、metadata/client_metadata 等控制与可选字段原样转发；只有 reasoning 内 null 成员、text.verbosity/format、tool_choice、parallel_tool_calls 的 null 在转发前移除。tools 缺省与显式空数组保持区别，不合成工具声明，也不静默删除工具声明。

Responses Lite允许在input原位置使用additional_tools包，包与其中工具原样转发，仅移除本地包 id；image_generation 不得出现在包或 namespace 内，只能作为受权限映射的唯一顶层声明。HTTP按Lite包或明确标记生成有限Lite header，WS生成每轮有限metadata标记，不透传任意header。原生WS每lane仅记最近成功响应的Lite标记、模型/响应ID；省略所有声明且同模型previous_response_id精确指向该响应才继承Lite模式，不跨lane/连接/失败恢复。

网关拒绝仍记录固定 code/reason 与服务端UUID，沿用16条/单调60秒全局诊断上限；提供者错误只额外记录短机器码 provider_code，不记录消息、字段值、工具名或请求正文。公开错误不包含内部 reason。历史日志未记录的信息不得事后推测为已确认根因。

## P16：受控模型目录

两个路径的 GET /models 返回有效白名单的 OpenAI data；只有所有模型均由显式内联或经验证私有快照提供完整 profile（非空 baseInstructions 或有效 upstream）时才同时提供同一集合的 Codex models，不裁剪成一个假装完整的子目录。所选客户端的 client_version 查询参数请求 Codex 目录；缺少完整 profile 返回 503 model_catalog_unavailable，普通模型列表仍可用。该查询参数只选择视图，不授予权限；503 不能阻止客户端自行 fallback，未采用目录不得算验收通过。

受信私有快照条目可提供 `upstream` JSON 对象，与 `catalog` 互斥；须有非空字符串 `base_instructions`，`slug` 若存在必须等于配置模型 ID，单条序列化上限 256 KiB，快照文件上限 4 MiB。未知成员（含嵌套对象）原样保留，不做字段白名单。目录以 upstream 为准，仅覆盖 slug 为配置 ID、priority 为配置顺序；visionInput 非 true 时从 input_modalities 删除 image；upstreamTransport 非 websocket 时设置 prefer_websockets=false；附加现有 codexone_profile 来源信息。所有模型均有完整 profile 才输出 Codex 目录，不输出部分目录。

旧 `catalog` 为兼容合成路径，行为保持；部署内联 catalog 对快照条目作整体覆盖，覆盖后沿用合成路径。模型基础指导会替换客户端默认指导，管理员须针对模型/版本审核；网关不复制或发明客户端默认提示。目录不授予额外权限，不证明提供者已支持声明的能力。

配置顺序决定 priority，目录内容（包括 upstream 及快照哈希）、指导与顺序进入策略版本；计价版本只包含模型 ID/费率，指导不进入核心持久库。实际版本须显式发现并采用目录和已配置指导，不得以 fallback 元数据下的生成成功充当目录验收。

## P17：Responses 流式压缩 v2

普通 /responses 的输入可含单个末尾 `{"type":"compaction_trigger"}`；该控制无 ID/状态/附加 payload，不与 generate:false 或独立 /responses/compact 混用。它使用 compact 执行模式与相同授权/准入/用量/归属屏障，传输仍走普通 HTTP JSON/SSE、桥接或原生 WS，不改路由为独立压缩端点。

对应输出允许 compaction 项无对象 ID，以非空 encrypted_content 的类型指纹先持久绑定，再暴露完整内容。仅 output_item.added 阶段允许缺失/空的未完成内容；done 必须完整。流式成功必须恰好一个 compaction done，与终态窗口中唯一 compaction 的内容/已提供 ID 一致，output_index 关联有界且必须对应终态 output 数组中该项的实际位置；JSON 成功窗口同样只接受一个完整项。不得在压缩中创建新的客户端工具调用；未支持对象及不一致窗口明确失败，已经观察到的可信用量继续结算。终态缺失保持 unknown，不把 added 或 done 当作执行完成。

普通 Responses 的压缩响应 ID 属于该执行的 response，可按归属用作 previous_response_id；它与独立 compact 返回的 compaction 操作 ID 不同。客户端自行重建后续窗口，完整加密上下文按 P15/I11 验证；网关不自动补正文或重放执行。[CLI 0.163.0 实现依据](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/src/compact_remote_v2.rs)

## P24：订阅池 HTTP 装配

订阅池复用既有 JSON/SSE/compact 的客户端校验、提供者观察、绑定屏障和累计用量契约；当前托管 Key 与模型白名单先于路由。Core 原子选择后仅向选中身份的固定目标发送一次 POST，认证头由可信 work 装配，下游 Authorization/account/组织/项目头不透传。HTTP client 禁止重定向、连接建立重试、代理继承和解压，使用 HTTP/1 及单次连接；不能安全重放的失败返回并收尾。

池的原生 WS 只在明确配置 websocket 上游时升级；身份固定见 P26。临时账号不可用/需要刷新、刷新授权失败/冲突/容量/存储失败使用脱敏的类型化错误码，不回传上游错误正文。就绪状态读取当前账号并结合存储及运行 owner，不把空池配置当可用账号。

## P25：池 HTTP→WS 桥接

私有配置可明确选择 HTTP 或 websocket 上游，缺省为 HTTP；不接受任意 URL、header 或其他传输值。传输进入有效策略摘要，不改变相同模型价格的摘要。HTTP→WS 在唯一持久准入后用所选 work 的固定目标与认证头建立一次上游连接，再执行一个 turn，向下游返回 JSON/SSE；握手或传输失败只收尾该 attempt，不另连/换账号重放。独立 compact 继续使用所选身份的 HTTP compact 路径。

网络观察/绑定/用量逻辑与原生单身份 WS 共用。已知关闭或无效的既有 peer 须在新 turn 准入前拒绝，不能为了重构在坏连接上新增 intent；桥接新 peer 在其已持久上下文中准备。桥接的配置总期限包含连接、TLS、升级和 turn，超时关闭并等待其 socket，不仅约束握手后的正文。


## P26：池原生 WS 连接归属

升级仅验证当前 Key 和连接容量；首个有效 create 才在 Core 原子选择账号并持久准入，之后用该 work 建立一次上游 socket。连接固定 principal 下的 namespace/identity，默认及所有命名 lane 逐 turn 重验当前 Key、账号/凭证和归属交集，不能因无 previous ID、刷新或新 lane 另选账号。draining 允许已固定连接续接，disabled 阻止新 turn；认证或上游失败只结束原 attempt/连接，不重连重放。

首个执行 owner 与连接 owner 是同一结构化任务组的兄弟，通过容量一交接传递首 context/认证及首 turn 结果。首 turn 结束立即交回自己的最终化 ticket，上游 socket 仍由连接 owner 监督；后续 turn 独立准入和最终化。首执行的配置总期限包含连接与升级；首准入失败、超时、下游断开或 Runtime 关闭必须结束交接双方并等待网络任务。保持 P13/P14 的 lane、排队、帧和连接寿命边界，共用协议/用量观察，不新增恢复或自动重试语义。

图片原生入口的配置、透传、并发与期限见[图片配置](../development/images.md)。所有入口将能力要求随 admission 持久保存并在原子准入复核；Images 不再选择宿主或改写为 Responses。原生非流式 200 仅在有效 data[].b64_json 非空时判成功；SSE 仅可信图片 completed 事件及有效图片授予完成证据。Responses 托管图片工具仍以可信 response.completed 判定，output_item.done 与预览不承诺整个操作成功。

数据服务持有一个 48 MiB 共享正文预算。超过 8 MiB 时计入整个正文：HTTP Content-Length 在读取前一次申请，chunked 随读取增量申请；WS 单帧按声明长度、分片随聚合增量申请，均在缓冲前取得租约。预算不足不排队：HTTP 503 capacity_exhausted、Retry-After: 1；WS 带 status: 503 的 error 帧并丢弃整条消息、保持连接。超过 32 MiB 为 413。解析/派发结束、失败、断开、超时及连接关闭均归还租约，重复释放幂等。预算约束原始正文，不等于进程 RSS；JSON 树、序列化及 base64 会产生额外内存。Images multipart 校验后转换为原生 JSON（24 MiB 图片编码为 32 MiB），不再构造工具封套；原生 Images 响应上限 48 MiB，Responses 图片工具上游限制不变。

可信离线profile导入及字段边界见[模型快照](../development/model-profiles.md)。目录的codexone_profile仅披露来源标签/版本/字节摘要/采集时间/客户端清单/覆盖与30天陈旧标记，不含本机路径；codexone_execution_budget披露有效三阶段秒数及默认/配置来源。均不授予权限或承诺客户端/提供者兼容，缺模型拒绝新启动，不静默替换。

## 可信上游出网代理

CODEXONE_UPSTREAM_HTTP_PROXY为可信进程配置，未设置或空值直连；非空仅接受http://host:port及可选根斜线，不接受userinfo、非根路径、query或fragment。无效值在启动/check-config拒绝且不回显；不自动采纳HTTP_PROXY/HTTPS_PROXY/NO_PROXY或下游headers。生成HTTP、原生WS、认证/刷新及额度GET统一使用该代理，管理/健康监听不改变。代理失效不得回退直连、重定向或重放已派发请求；提供者authority和TLS主机名/证书校验保持。

原生WS先完成有界HTTP CONNECT，再在隧道内对原目标握手TLS/WS，CONNECT不含订阅Bearer或下游凭证；代理握手复用连接owner/期限/取消关闭路径。代理拒绝与提供者拒绝分别分类；有可信HTTP状态时仅记录100—599整数、固定错误码/reason及服务端UUID，受既有16条/60秒限额。不记录代理地址、提供者错误正文、任意字段或标识，不在公开envelope增加内部字段。已知不支持max_output_tokens仅记固定分类，不静默删掉请求约束。没有用量证据的失败继续保留unknown责任。

Responses HTTP流的200响应允许媒体类型缺失/空值，仍须通过原有有界SSE解码、事件/模型/对象归属、终态与可信用量验证；不将无头HTML/JSON/空流当成功。非空媒体essence须精确为text/event-stream，参数/大小写允许，相似前缀与JSON/HTML拒绝。每进程最多一次缺头观察仅记固定事件/UUID/200，与16条拒绝预算独立；拒绝媒体仅记固定JSON/HTML/other，不记录原值或正文。

JSON响应的头/正文/end作为同一有界writer sequence提交，沿用5秒写期限/背压，不能在正文与end之间独立异步让出而留下合法快速关闭的窗口。Responses完整成功终态通过校验/绑定并成功提交下游writer后，同步观察成功结果，再做期限任务组等收尾；迟到关闭不改写已观察结果。提交失败/部分输出/仅usage/item.done/隔离扩展均不观察成功，failed/incomplete既有失败观察保持优先；不忽略写错，不承诺对端已收到/消费或执行工具。可信用量及unknown责任仍独立持久。

usage 只解释 input_tokens、output_tokens 与 input_tokens_details.cached_tokens 作为计量证据，值须为 0—1000000000 整数；畸形计数不形成证据（完整度 partial 或无证据，账本保持 unknown），不使执行失败。向客户端只输出非负整数的 input/output/total 及 cached/cache_write/reasoning 明细，其余 usage 成员不出网关。


## 请求契约选择

可信配置选择responses或codex-subscription请求契约，不能由下游覆盖；账号池与非loopback订阅固定后者。普通订阅HTTP使用stream=true/store=false；下游JSON仅提交已验证终态，SSE逐事件提交。显式store=true及HTTP previous_response_id准入拒绝（包括HTTP→WS新连接桥接），原生WS保留同连接续接。订阅普通路径非null max_output_tokens/temperature/top_p/truncation/prompt_cache_retention/metadata返回400 unsupported_backend_parameter，不静默删除限制；其null在组装时移除；service_tier 等其他字段透传。字符串input映射为等价user消息数组。图片和独立compact不随此扩展或改变消费语义。合成验证不替代真实客户端/模型验收。


普通订阅WS组包保留stream=true/store=false，与固定Codex客户端ResponseCreateWsRequest一致；通用responses WS仍按其隐式流规则移除stream。不得把公开API的WS规则推导为订阅后端规则，图片沿独立契约。

## P27：开放协议透传

客户端与提供者协议持续演进，网关不以封闭允许集合解释它们。复盘与取舍见 [开放协议透传](../changes/open-protocol-passthrough/proposal.md)。

- 请求：Images JSON 原字节转发，仅缺 model 时补部署默认并重新序列化；multipart 仅在 /v1 edits 转换为原生 JSON。未知字段保留，尺寸/质量/背景/格式/fidelity/n 由提供者判定；网关检查模型/Key 授权、stream 类型、内联参考图与容量边界，对象须含字符串 image_url。Responses 除 P09/P13/P15 列出的网关职责外，未知字段、条目、part 与工具声明原样转发。仍拒绝 background=true、conversation/prompt、HTTP generate、错位或带成员的 compaction_trigger、非布尔 store/stream、包内或 namespace 内 image_generation、未拥有的硬引用。任何位置的 input_image（含工具结果数组）要求视觉权限；Images 参考图/mask 只接受有界内联 PNG/JPEG/WebP，mask 参数关系交由提供者判定。
- 响应：只提取 response ID、条目 ID、call_id、reasoning/compaction 指纹、已知计数和终态；未知字段、条目类型、part、annotations、状态值、回显与输出项数不导致失败，未知事件原样转发给流式客户端但不授予归属/用量/终态。普通输出不再做多视图语义关联，流式压缩不再做窗口一致性校验。绑定对同一主体/身份幂等，每 attempt 最多 1024 个，超出后续对象不绑定。
- 提供者错误：保留 type/code/param/message/plan_type/resets_at/resets_in_seconds，message 中 org-/user-/proj-/acct 标识和邮箱替换为 [redacted]，附网关 request_id。HTTP 非200 返回对应 4xx（401 映射 502 upstream_authentication_rejected，5xx 映射 502/503）；429/额度类错误为 429 并按 resets_in_seconds/Retry-After 设置账号 cooldown。SSE 已开始时以 response.failed 下发，原生 WS 以带 status 的 error 帧下发且连接保持；response.failed 终态原样下发、error 脱敏，结果记为失败并保留可信用量。

原生 Images 两前缀均 POST 至所选身份上游 /backend-api/codex/images/generations|edits；与 Responses HTTP 共用受限客户端标识头，额外转发 x-codex-image-turn-id，账号认证由服务注入。回传 x-codex-imagegen-request-id 和网关 x-request-id。服务持有独立 imageConcurrency 许可池（1—8、默认2），等待最多30秒；超时429 image_capacity_exhausted / Retry-After: 1，无 intent/派发。成功、失败、取消与断开均只归还一次许可；账本未知责任不随许可归还而释放。
