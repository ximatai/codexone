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

发布清单按“后端 × 客户端版本 × 端点 × 传输 × 执行模式 × 工具”列允许组合；未知组合在 dispatch 前拒绝，不靠透传假设语义相同。元数据扩展字段可保留，执行控制、工具、外部对象引用采用允许列表。适配器声明支持组合，发布夹具证明该声明。

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
| conversation、远端 MCP、内置检索/容器、通用文件上传/读取 | 首版关闭，直到归属、成本及生命周期有独立契约；不是“普通工具透传” |
| 后台任务、steering、未实现的取消/控制事件 | 首版拒绝；只允许经过契约验证的 turn 级取消，否则采用连接级关闭策略 |
| GET/delete/cancel response | 不承诺公共对象服务；仅适配器拥有且不暴露给客户的核对接口可内部使用 |

保留允许的未知事件/字段时，也必须保证它们不引入未识别的可引用对象。适配器的事件策略分为：可透明数据、含归属对象需屏障、终态/usage、未支持控制。未知普通事件可透传；未知执行控制或对象创建事件终止为协议不支持，不以“透明”绕过准入。

## P10：重试、超时与外部错误

默认无输出也不等于可重试。未发送请求可有限重选；适配器明确证明未执行的拒绝可按总 deadline/attempt 预算重试；已发送后断线/超时、已返回 ID 或语义输出一律不透明重放。跨账号还需全部引用无归属冲突且主体允许。旧凭证 401 只有明确拒绝未执行时，单飞刷新后最多重试一次；429 尊重 Retry-After，固定谱系不跨账号。一次重试有独立 attempt 和上游成本记录。

排队、连接/TLS、响应头、首语义事件、活跃进展、下游写、总 turn 和连接寿命分别限时。NIO channel close 即使上游静默也必须触发下游取消；图片/思考可有较长 idle 策略，但不延长慢消费者期限。单调时钟用于 deadline，UTC 用于账期。

网关错误保持协议 envelope、稳定 code、脱敏信息与 request ID；区分权限、quota、capacity、unknown/ambiguous binding、上游状态丢失、授权需要更新、client_too_slow、execution_indeterminate。HTTP 提交前可回 4xx/429/502/503/504；提交后仅协议错误事件或异常关闭。WS 握手后不可返回 HTTP 状态响应；lane 错误服从执行生命周期规范的 FIFO。失败不伪装成功、EOF 不视为终态。

## P11：Desktop 与现有接入兼容

首版必须以明确版本的 Codex Desktop 为主要真实客户端，CLI 为补充；允许清单必须覆盖实际使用的模型选择/目录、HTTP JSON/SSE、WS、连接预热、压缩、工具结果提交和续接。仅 CLI 成功不得表示 Desktop 通过；warmup/compact 不得在首版替代验收中整体标为可选而跳过。具体模型、参数与客户端版本由验收矩阵声明，未验证组合明确拒绝。

必须验证标准 `/v1` 入口与现有 `/backend-api/codex` 前缀下的 responses（HTTP/WS）、models、responses/compact、images/generations 和 images/edits 等价路径，记录斜杠、认证、错误及模型元数据行为；不要求复制无关旧 API。HTTP 下游直连 HTTP 上游、HTTP 下游桥接 WS 上游及原生 WS 路径均须有外部行为验证。实现可复用或替换旧桥接设计，但不得因连接复用改变身份、重试与结算约束，也不得通过客户端全量改成另一传输来跳过验收。能力协商头只能表示能力，不得替代本地 Key 授权。

## P12：有边界的图片生成与编辑

Images generation/edits 是下游产品入口；上游可通过已验证的 Responses 图片工具适配，不要求提供者具有同名 Images 端点。必须明确输入输出映射、模型/参数、错误 envelope、使用量与终态含义，不能依赖对话模型名称推导生成权限或硬编码唯一编程模型。

edits 必须支持已验证 Desktop 参考图编辑契约所需的图片输入（含适用的 multipart）、返回格式及流式行为；图片数量、类型、解码尺寸、multipart/掩码与输出均有界，未支持组合在 dispatch 前拒绝。直接提交的图片数据无需先开通公共文件上传/读取；不得默认抓取任意远端 URL。编辑与生成复用图片能力判定和执行治理，视觉输入仍单独判定。客户端对已完成编辑主动发出下一次编辑属于新执行；网关不得将断线恢复自动变为重新编辑。

## P13：受控单身份 HTTP 配置契约

单身份 Key 先验证，再由应用层按模型与每个引用的主体/命名空间/身份判定准入。模型目录仅列可信配置允许的模型。`/v1` 与 `/backend-api/codex` 的显式 HTTP 路由共用同一授权和执行用例，不做任意后缀匹配；尾斜杠未定义时明确拒绝。HTTP 请求以 `application/json` 输入，不接受压缩请求体或未知执行字段；客户端 function/custom 工具按 type/namespace/name 与返回调用匹配，namespace 只组织客户端工具，不开放内置检索或服务端执行；不接受未经声明的工具或对象类型。

文本 HTTP 切片的请求体为 512 KiB、JSON 深度 64、输入项 256、工具 64、引用 32；上游 JSON 为 256 KiB，单 SSE 事件 256 KiB、累计流 8 MiB。连接最多 32，入站异步通道高/低水位为 4/1，单次接收分配最大 64 KiB；请求读取 10 秒、上游建连 5 秒、读取 30 秒、发送至响应体消费/输出的单调总期限默认 120 秒（可信配置可缩短至 1—120 秒），下游写入 5 秒超时关闭连接。后续图片使用独立验证过的负载边界，不沿用文本限制冒充图片能力。

归属持久屏障在每个含对象的上游事件写下游之前完成；可信终态用量先观察，再做归属/输出检查，输出失败不抹去已知用量。上游 EOF、无终态或缺失用量不得伪造成成功/零消耗。部分证据的计数只表示已观察下界，完整度为 partial，继续保留未知暴露。发生核心持久故障后停止后续发送，数据/管理 readiness 反映不可用，liveness 不作为账号额度判断。错误使用固定脱敏 envelope 与请求 ID，不输出上游原始错误或请求秘密。

配置与文件安全说明见 [单身份配置](../development/single-identity.md)。Desktop、WS、预热、压缩的最终兼容验收仍按 P11，不能从 HTTP 合成结果推导。

## P14：单身份 WS 连接与 lane

配置 websocket 上游后，原生 WS 与 HTTP→WS 桥接复用相同持久准入/屏障/用量用例。握手只本地授权/容量管理，首个有效 create 才建立固定身份 socket；同 lane 串行 FIFO、跨 lane 可并行，不重连重放。stream_id 为 1—256 字节 ASCII 字母/数字/下划线/点/连字符，最多 32 个命名 lane（另含默认 lane），最多 16 个在途 turn；超限终止连接，已 dispatch 执行按原证据最终化。generate:false 使用独立 warmup 模式，仍占准入与未知暴露，不假设免费；只允许无生成内容的响应生命周期事件。未支持控制明确拒绝；真实客户端仍按 P11/E10 验收，不从合成 WS 切片推导完整客户端支持。

帧/聚合 512 KiB，单上游事件 256 KiB、累计执行 8 MiB；每 peer 入站队列及原生请求调度队列分别共享 64 条/1 MiB 上限，每 lane 最多排队 4 条，另持有一个有界 producer 消息；至多 33 个 lane worker，各自最多处理一个有界命令，5 秒拥塞终止连接；单 reader、串行 writer，校验 mask 角色/RSV/UTF-8，控制帧由框架校验并本地处理 ping/pong。首 create 10 秒、后续请求读取空闲 120 秒、连接寿命最多 1 小时；执行使用 P13 总期限，慢下游写 5 秒关闭。关闭 owner 覆盖未完成握手及已连接 socket，取消并等待子任务，不等待结算形成循环。

HTTP 桥接每执行新建上游 socket，不保证跨请求 store=false 连接缓存；原生 WS 续接使用原 socket。上游 reader 在入队前验证当前 turn 的 created/response ID/item 关联，并通过已准入 attempt 注册的同步证据 sink 观察终态用量，其他 lane 失败不得清除已接收/分类的可信用量；轮外事件、重复终态/response ID 关闭连接，不得将旧事件用于新 attempt。单连接最多 256 个响应、单轮最多 256 个 item。终态与 EOF 同到时，消费已进入有界队列的事件后再报告 EOF；已观察用量不因网络关闭丢弃。连接关闭不证明上游未执行，未观察终态保持 unknown。

下游 WebSocket 扩展提议可以存在，网关忽略提议且不返回扩展协商头；没有实现压缩，不接受未协商 RSV 帧。不能因客户端提供可选压缩提议而拒绝整个握手并将 HTTP fallback 误算为原生 WS 成功。未支持的子协议仍拒绝。实际客户端检查须分别证明直连、桥接与原生连接行为，而非仅最终回答成功。

## P15：客户端上下文与前台模式

完整 inline 消息及 function/custom tool 结果中的 id 为客户端本地关联标签，发送上游前移除；正文、工具 call_id 和显式引用保持。携完整 encrypted_content 的 reasoning/compaction 以 I11 类型指纹证明正文归属，发送前也移除客户端本地 id，不要求该标签已在上游绑定。显式 item_reference、previous_response_id、函数 call_id 和无完整内容的 reasoning ID 仍按归属查验；不能用本地标签触发上游私有读取。reasoning.encrypted_content include 可用，正文指纹在准入前校验，篡改/跨主体仍拒绝。

WS generate:false 为 warmup，普通 HTTP 不接受 generate 控制；预热只返回无生成内容的 response.created/in_progress/终态，不能伪装普通生成或默认记零。独立 HTTP POST /responses/compact 为 compact 模式，两个前缀共用授权/限额/屏障；即使生成走 WS，compact 仍走同可信 origin 的 HTTP 显式端点。返回 response.compaction 的完整 output 窗口不裁剪，不把 compaction ID 当 previous_response_id；保留的已有引用沿原归属，新引用先绑定，再整体返回；压缩窗口内的工具调用/结果必须来自已授权输入 call_id，不能创建新客户端工具执行。压缩请求沿文本 512 KiB、输出 256 KiB/256 项、总期限及失败语义；未支持模式/输入不发送。

兼容的客户端 metadata 只允许有界字符串字典；stream_options 仅 include_usage。文本/推理内容分类型校验，不透传未经分类的文件引用、注解或嵌套对象；工具结果的可选 name/namespace 和状态等字段同样按标量校验。提供者原始错误使用脱敏错误替代，响应回显的 previous_response_id 必须匹配已授权输入；可信计数仍在输出分类前记录。客户端须显式关闭本阶段未支持的内置 web_search；网关不静默删掉工具声明以制造兼容结果。

## P16：受控模型目录

两个路径的 GET /models 返回有效白名单的 OpenAI data；只有所有模型均显式配置非空 baseInstructions 时才同时提供同一集合的 Codex models，不裁剪成一个假装完整的子目录。所选客户端的 client_version 查询参数请求 Codex 目录；缺少完整 profile 返回 503 model_catalog_unavailable，普通模型列表仍可用。该查询参数只选择视图，不授予权限；503 不能阻止客户端自行 fallback，未采用目录不得算验收通过。

可信本地 profile 可限定展示名称、说明、上下文窗口、推理选项及模型基础指导。baseInstructions 是权威模型指导，客户端采用后会替换自己的默认指导，不能仅为目录解码提供空字符串；管理员须为目标模型/版本明确配置完整指导。网关不复制/发明客户端默认提示。当前切片只声明文本输入、无内置搜索；shell_type 选择客户端 unified_exec，工具仍遵守其 sandbox。目录不授予额外权限，不证明提供者已支持这些能力。

配置顺序决定 priority，目录内容、指导与顺序进入策略版本；计价版本只包含模型 ID/费率，指导不进入核心持久库。实际版本须显式发现并采用目录和已配置指导，不得以 fallback 元数据下的生成成功充当目录验收。

## P17：Responses 流式压缩 v2

普通 /responses 的输入可含单个末尾 `{"type":"compaction_trigger"}`；该控制无 ID/状态/附加 payload，不与 generate:false 或独立 /responses/compact 混用。它使用 compact 执行模式与相同授权/准入/用量/归属屏障，传输仍走普通 HTTP JSON/SSE、桥接或原生 WS，不改路由为独立压缩端点。

对应输出允许 compaction 项无对象 ID，以非空 encrypted_content 的类型指纹先持久绑定，再暴露完整内容。仅 output_item.added 阶段允许缺失/空的未完成内容；done 必须完整。流式成功必须恰好一个 compaction done，与终态窗口中唯一 compaction 的内容/已提供 ID 一致，output_index 关联有界；JSON 成功窗口同样只接受一个完整项。不得在压缩中创建新的客户端工具调用；未支持对象及不一致窗口明确失败，已经观察到的可信用量继续结算。终态缺失保持 unknown，不把 added 或 done 当作执行完成。

普通 Responses 的压缩响应 ID 属于该执行的 response，可按归属用作 previous_response_id；它与独立 compact 返回的 compaction 操作 ID 不同。客户端自行重建后续窗口，完整加密上下文按 P15/I11 验证；网关不自动补正文或重放执行。[CLI 0.163.0 实现依据](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/src/compact_remote_v2.rs)
