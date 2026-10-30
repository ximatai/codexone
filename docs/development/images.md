# 图片入口与部署配置

图片能力使用既有单身份/订阅池配置中的可选 `imageGeneration`。宿主模型显式声明 `imageGeneration: true`；需要视觉对话时另声明 `visionInput: true`，不能通过模型名推测。示例仅为合成命名，不表示真实提供者可用性：

```json
{
  "models": [{"id": "synthetic-host", "visionInput": true, "imageGeneration": true, "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0}],
  "imageGeneration": {
    "defaultModel": "synthetic-image",
    "models": [{"id": "synthetic-image", "hostModel": "synthetic-host", "sizePolicy": "fixed1536", "supportsTransparency": true, "supportsInputFidelity": true, "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0}]
  }
}
```

这是配置片段；其余必填字段见[单身份](single-identity.md)或[订阅池](account-credentials.md)。最多 16 个图片映射，与对话模型 ID 不重名。`fixed1536` 接受 auto/1024x1024/1536x1024/1024x1536；`flexible3840` 接受 auto 或长边不超过 3840、边长为 16 的倍数、宽高比不超过 3、总像素 655360—8294400。透明背景须声明支持且输出 png/webp；input_fidelity 须声明支持。宿主和图片费率均为本地估算配置，不能当订阅账单。

`/v1` 和 `/backend-api/codex` 均提供 `/images/generations`、`/images/edits`。生成 JSON 包含 prompt；编辑 JSON 包含 prompt 与 `images: [{"image_url": "data:image/png;base64,..."}]`，或 multipart 的 prompt、image/image[] 文件字段；可选单份 mask。只接受内联 PNG/JPEG/WebP，不抓取远程 URL、不提供文件托管。mask 必须为与首图同尺寸的有 alpha PNG。

含图片历史及图片工具可与独立 compact、流式压缩组合，仍分别检查视觉与图片权限。初始支持 n=1、base64 输出及 `stream`；size/quality/background/output_format/output_compression/moderation/input_fidelity/partial_images 按映射验证，不支持的参数在生成前拒绝。Responses `image_generation` 工具的 model 缺省使用明确部署默认值，图片模型须在 Key 有效 imageModels 中，本次对话模型须由 Key 授权且配置声明 imageGeneration: true；hostModel 仅用于 Images 入口选宿主。历史 `image_generation_call` 的 ID 只可在同主体/同身份归属验证后续接。

每请求最多 32 MiB 正文（HTTP JSON/SSE、multipart、WS 消息及分片聚合）；最多 16 张参考图，每张解码最多 16 MiB，图像与 mask 合计最多 24 MiB，单图最多 50,000,000 像素，不设总像素上限。Images 未知顶层字段及参考图/mask 对象额外成员丢弃，对象须含字符串 image_url。容器结构校验不做栅格解码或加工；不代表提供者会接受全部容器。全数据面最多 8 条连接；上游 WS inbox 为 8 MiB，下游 inbox/调度队列各至多 48 MiB，且大正文租约共享全局预算，每次最多 16 个执行 ticket，保留有界任务与关闭路径。图片上游每事件最多 8 MiB、总事件最多 32 MiB；非图片执行保持原文本事件限制。HTTP 上传总期限 10 秒；执行总期限默认600秒、可配置1—1800秒，首响应/进度空闲默认30/60秒（见P13），出站写入期限 5 秒。达到上限返回失败，不自动重发。

Images 流输出 `image_generation.partial_image` / `.completed`，编辑为 `image_edit.*`；预览不代表生成已完成。只有可信 response.completed 及有效最终图片才发送 completed；provider failed/incomplete、畸形结果或缺少终态不承诺成功。响应/图片项 ID 暴露前必须完成持久归属。一次操作一个持久 intent；断线、取消或未知结果不能重生成或切账号重放。下一次主动编辑是独立新执行。

用量分别呈现宿主响应 token、图片工具输入/输出 token 与已观察图片数；工具 token 不加入宿主 token 总数。宿主和工具费率分别估算后相加。没有可信完整工具用量时保留 partial/unknown 和预留暴露，缺失指标为不可用，不填零；结果成功与用量结清分别解释。图片内容与 prompt 不写入核心库。

图片权限语义自 schema v6 引入；当前 schema 的离线迁移与备份见 [Key 治理](key-governance.md)。合成协议检查与实际 Desktop/真实订阅兼容是不同证据，后者须显式授权并逐项验收。

数据服务持有一个 48 MiB 共享正文预算。超过 8 MiB 时计入整个正文：HTTP Content-Length 在读取前一次申请，chunked 随读取增量申请；WS 单帧按声明长度、分片随聚合增量申请，均在缓冲前取得租约。预算不足不排队：HTTP 503 capacity_exhausted、Retry-After: 1；WS 带 status: 503 的 error 帧并丢弃整条消息、保持连接。超过 32 MiB 为 413。解析/派发结束、失败、断开、超时及连接关闭均归还租约，重复释放幂等。预算约束原始正文，不等于进程 RSS；JSON 树、序列化及 base64 会产生额外内存。Images multipart 校验后内部封套上限 33 MiB（24 MiB 图片编码为 32 MiB，加有界提示与工具），不得由网络字段选取；上游事件限制不变。
