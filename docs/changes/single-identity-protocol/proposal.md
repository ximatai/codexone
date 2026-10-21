# M2 单身份协议闭环

## 目标与范围

依据 P01—P12、E01—E11、I03/I04/I05、O09/O10/O12：将 M1 执行内核接到一个可信 principal/Key/上游身份，交付模型目录、HTTP JSON/SSE、原生 WS、HTTP→WS 桥接、客户端函数工具、预热、压缩与续接。默认真实 loopback 合成上游，真实订阅调用另经授权；fixture 与客户端兼容证据分别报告。

本阶段不实现账号池/刷新、图片生成、恢复正文库或完整业务管理台。提供本切片所需最小安全配置：客户端 Key 验证、只读外部凭证、明确模型/工具允许范围、固定身份和上游 origin、脱敏错误；不提供任意代理或未经验证的控制事件透传。

## 实现顺序

1. 明确配置、准入/引用校验和 wire 分类；HTTP JSON/SSE 与核心持久化纵向接通。
2. 原生 WS lane 的 FIFO、身份与有界队列、单 reader/writer；覆盖预热及 HTTP→WS 适配。
3. 压缩、工具结果与续接；核实明确版本 Desktop/CLI 的模型元数据、认证头与路径行为。
4. 对照断线/上游提前关闭/重启/过期形成恢复可行性结论，供 M5 使用。

## 验收及未知项

真实 socket 验证 `/v1` 与 `/backend-api/codex` 的模型、responses 和 compact 路径、斜杠/认证/错误；准入前失败不触发上游，ID 提交失败不暴露，终态用量先观察再下发；断线取消不重放，未知执行持久保留。测上游 EOF、错误 envelope、慢消费者/背压、请求/事件/帧/聚合与队列硬限、子任务取消/关闭/等待和句柄回收。数据库与网络不跨事务持锁。

官方 WebSocket 契约区分 connection-local cache、previous_response_id 及完整/压缩 input；连接关闭不保证上游续接仍可用。缓存正文不自动等价于 Desktop 消费已有输出。需核实客户端是否存在安全的读取/恢复动作，不自行发明私有协议或自动重新执行来伪装恢复。

真实 Desktop、订阅账号及反代的最终验收不能由合成测试代替。实现和无凭证验证自主推进；缺少授权或无法确认的业务边界记录在 STATUS，不虚构通过，不改动旧服务。变更不迁移旧库或旧 Key；非空 schema 变化沿用显式备份/迁移约束。

## WS 实现切片

先交付默认串行 lane 与 HTTP→WS JSON/SSE 桥接，再扩展命名 lane/预热/压缩。首个切片默认串行 lane，后续扩展最多 32 个命名 lane/16 个在途 turn；继续拒绝未支持控制，不宣称完整 M2。HTTP 上游模式不开放原生 WS；配置 websocket 模式后，原生连接绑定单个上游 socket，HTTP 桥接每执行使用独立上游 socket，不保证跨 HTTP 请求的 store=false 连接缓存。连接关闭或协议错误不重连重放。

握手只本地认证/容量检查，首个可解析且允许模型的 create 才连接固定上游。原始 accepted/connecting channel 在协议协商前即纳入 owner，关闭时包含未完成握手；一个 reader/一个串行 writer。帧及聚合 512 KiB，每 lane 队列 4 条，每 peer/调度队列分别共享 64 条/1 MiB，单 producer 取得空间后才继续读取；拥塞 5 秒、首 create 10 秒、后续请求读取空闲 120 秒、连接寿命 1 小时。WS 终态仍先观察用量、绑定再发送；终态与 EOF 同到达时排空已有事件，不以 TCP 关闭抹去证据。

## 预热、压缩与客户端上下文

执行 admission JSON 增加可选 mode（generation/warmup/compact），缺失按 generation 解释以兼容现有 v1 数据；不增加核心表/SQL 列，不将预热混入生成统计。三种模式均占请求/并发/未知暴露治理，预热不假定免费，缺失可信用量仍保留 unknown。WS generate:false 只在原生 WS 开放，不通过 HTTP 静默改写为普通生成。compact 使用单独 HTTP `/responses/compact`，返回压缩窗口而非可当 previous_response_id 的生成响应。

reasoning/compaction 的 encrypted_content 在对外输出前将类型隔离的 SHA-256 指纹绑定到主体/命名空间/身份，输入必须解析为已有归属；核心只保存指纹与对象 ID，不保存正文/密文内容。命名空间/自定义工具仍是客户端执行工具，按声明的 type/namespace/name 验证返回调用，网关不执行工具；首版内置检索关闭不因客户端默认声明而开放，客户端兼容配置需显式禁用该能力。

实际 CLI 首轮为完整 inline 的用户/开发者消息生成本地 ID；将这些都当作已有上游引用会阻断正常首次执行。对完整消息、function/custom tool 结果在发送前移除其本地 id，避免猜测 ID 被提供者解释为私有读取；正文、工具 call_id 和显式 item_reference 不改写。assistant 的完整纯文本消息也走 inline 语义；需要保留上游对象身份时必须通过显式引用。reasoning/compaction 的 id/指纹及工具 call_id 仍查归属，不能借本地 ID 绕过。验证覆盖首次请求、本地工具结果回传、伪造上下文与跨主体引用。

## 模型目录与 Desktop 验收准备

模型目录同时提供 OpenAI data 与 Codex models 两种结构，均只来自同一允许模型配置；Codex 展示元数据可显式配置名称、描述、上下文窗口与推理选项，不从模型名称猜测价格/授权。默认文本能力、不宣称图片/内置检索，窗口采用保守配置值；目录与执行仍共用精确模型允许集合。展示字段不改变计价版本，授权/协议/目录快照进入策略版本。

桌面验证优先使用明确版本应用的独立用户数据及临时 CODEX_HOME，不改个人配置/登录；无凭证合成 provider，真实订阅另授权。若当前应用本身无法安全隔离或客户端入口不支持所需契约，保留证据与未验收项，不冒充通过。
