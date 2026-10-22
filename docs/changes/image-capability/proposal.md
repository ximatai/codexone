# M4 图片生成与参考图编辑闭环

## 目标和依据

按 P12、I03/I09、U03/U05/U10、A02/A09 推进同一业务闭环：Images generations/edits、Responses 内置图片工具、视觉输入及独立授权、管理表单、用量解释和真实合成 socket/界面操作。阶段内主 Agent 亲自实现与定向验证，闭环完成后集中提交/review/修复、一次完整跨平台出口。Desktop 与真实提供者验收单列，不能从 fixture 推导完成。

## 授权、模型和持久屏障

Key 分别保存对话 models、visionInput、imageGeneration 和 imageModels。旧策略缺字段默认关闭新能力；关闭生成不关闭已授予的视觉对话。允许仅图片的 Key，但须有明确图片模型范围。Images generation/edits 共用 imageGeneration 与 imageModels；编辑图片是该生成操作的输入，不额外要求对话视觉权限。Responses 图片工具仍须对话模型授权及同一图片授权。

部署显式配置图片模型到宿主 Responses 模型的映射、默认图片模型、参数能力及估算价格；不硬编码唯一编程模型，不用对话白名单猜测生成权限。Images 的内部宿主不要求出现在用户对话范围，账本记录公开图片模型；直接 Responses 工具必须匹配该对话模型的配置。目录、执行、别名和准入使用同一有效策略。能力要求随 admission 持久保存，SQLite 同事务复核当前 Key revision/能力/模型；schema v6 语义升级保护旧二进制，v1—v5 显式离线私有备份迁移，历史未携要求按纯对话解释，不改写历史。

## 请求和传输

两种前缀 `/v1`、`/backend-api/codex` 提供 generations JSON、edits JSON data URL 与 multipart。初始 n=1，不将多图拆成隐藏多次生成。JSON 编辑接受 images[].image_url；multipart 合并 image/image[]，可有一份 PNG mask，经验证放入工具 input_image_mask，而非误作额外参考图。参数按显式能力检查：size/quality/background/output_format/output_compression/moderation/input_fidelity/action/partial_images；不支持的组合在派发前拒绝。默认不抓远端 URL、不提供公共 Files 服务、variations 或永久图片 URL；输出为 base64。

图片仅驻留有界瞬时缓冲；认证与容量先于大正文，按路由/内容实施字节、图片数量、格式/尺寸与总像素限制。初始上限须覆盖实际客户端参考图场景，并同时限制所有连接/排队/输出，不能只扩大单请求上限。PNG/JPEG/WebP 校验 magic/结构/声明尺寸，网关不作栅格解码或图片加工；容器检查不等于栅格解码或实际提供者接受；合成协议验收必须使用完整有效图片，不以任意 base64 或伪造头部充当有效图片。掩码检查 PNG、alpha 及首图尺寸。总期限覆盖上传/握手/正文，慢读、取消、过大或畸形输入均有 owner 和释放路径。HTTP/SSE、HTTP→WS 及原生 WS 使用相同图片观察与权限规则。

Images 流式映射规范 partial/completed/error，编辑使用 image_edit 前缀。预览不当完成结果；完整图片只在可信 response completed 且相关项/用量已处理后完成。不能因 output_item.done 抢先承诺最终成功。提供者 failed/incomplete、正文丢失和下游断开不重新出图，不跨账号重放。响应/图片 ID 在暴露前绑定，历史图片工具项续接须查主体/账号归属；不持久保存图像或提示词。

## 用量和观测

一次用户操作只创建一个 intent/finalizer owner，不用内部 loopback HTTP 生成第二套账本。图片项数量和可信工具用量独立观察，缺失不能填零；宿主文本用量与图片工具用量区分，不能将工具与响应总量重复相加。图片工具输入/输出 token 作为独立可空指标，费用按部署明确费率估算；没有可信完整工具用量时保持部分/unknown，预览不结清。现有关键结算/未知暴露/幂等与核心队列预留不变；统计及界面同步显示范围和不可用项。

## 验收与外部依据

使用无凭证合成提供者与有效合成图片，真实 HTTP/SSE/multipart/WS 验证：生成/参考图编辑/下一次主动编辑，独立权限矩阵、同主体/跨主体引用、禁用/CAS、宿主映射、部分预览与终态、工具用量/宿主用量不重计、超大/畸形/慢上游/断开/磁盘失败和关闭释放。实际浏览器操作管理权限并核对有效目录；随后集中 subagent review，主 Agent 修复。

官方公开 API 仅作 wire 依据，不证明订阅可用性或账户授权：

- [Image generation](https://developers.openai.com/api/docs/guides/image-generation)
- [Responses image tool](https://developers.openai.com/api/docs/guides/tools-image-generation)
- [Responses streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events)

旧服务仅核对已确认的入口/参数需求，不复用内部架构、重试或恢复取舍。未获授权不调用真实账号或付费生成；Desktop 实际图片/连续编辑和生产兼容留在明确验收矩阵，不自动标完成。
