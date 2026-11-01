# 图片入口与部署配置

配置图片生成、参考图编辑及其独立权限与用量边界。

图片能力使用既有单身份/订阅池配置中的可选 `imageGeneration`。图片模型只需 ID 和本地估算费率；对话的托管图片工具另要求对话模型显式声明 `imageGeneration: true`，视觉对话另需 `visionInput: true`。示例仅为合成命名：

```json
{
  "models": [{"id": "synthetic-host", "visionInput": true, "imageGeneration": true, "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0}],
  "imageConcurrency": 2,
  "imageGeneration": {
    "defaultModel": "synthetic-image",
    "models": [{"id": "synthetic-image", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0}]
  }
}
```

这是配置片段；其余必填字段见[单身份](../development/single-identity.md)或[订阅池](../reference/account-credentials.md)。最多 16 个图片模型，与对话模型 ID 不重名。旧 `hostModel`、`sizePolicy`、`supportsTransparency`、`supportsInputFidelity` 字段可省略；旧格式仍可读取，但不再影响路由、参数接受范围或费率。hostModel 不必指向已声明的对话模型。未知配置字段仍拒绝。`imageConcurrency` 是顶层整数，范围 1—8，缺省为 2，两种配置均可使用。

`/v1` 和 `/backend-api/codex` 均提供 `POST /images/generations`、`POST /images/edits`，使用所选身份的 HTTP 上游 `/backend-api/codex/images/generations|edits`，不再改写为 Responses，也不因对话配置为 websocket 改变图片传输。JSON 正文原字节转发；只读取 model/stream 以及内联图片的安全边界，缺 model 时插入部署默认模型并重新序列化。模型必须在部署列表及 Key 有效 imageModels 中，否则 403 model_not_allowed，且不创建 intent 或派发。图片编辑不要求视觉对话权限。

仅 `/v1/images/edits` 另外接受 multipart：image/image[] 文件变为 `images[].image_url` data URL，mask 变为 `{"image_url":...}`；n/partial_images/output_compression 为整数，stream 为布尔，其余文本保持字符串，包括未知字段。JSON 未知成员完整保留。尺寸、质量、背景、输出格式、透明度、fidelity、n 等由提供者判定；网关不扇出 n，不抓取 URL，不托管图片，不支持 variations。参考图/mask 只接受内联 PNG/JPEG/WebP，保留容器、字节和单图像素校验，不在本地加工图片或验证提供者 mask 参数矩阵。

客户端标识按[P28](../reference/specs/protocol.md#p28客户端标识与连接容量)统一：原生请求保留标识，非原生使用私有clientFingerprint的Codex CLI标识；session_id、x-codex-turn-metadata、x-codex-image-turn-id等沿Responses共用允许列表转发；账号 Bearer 与 chatgpt-account-id 由网关注入，不采用下游账号头。返回 x-codex-imagegen-request-id（包括提供者错误）及网关 x-request-id；错误 envelope 另含 request_id。提供者错误按 P27 脱敏/映射，429 触发账号冷却。

一次操作一个持久 intent，完成归属和准入后只派发一次；发送后不切账号、不重放。提供者输出前明确拒绝仅按[U13](../reference/specs/usage.md#u13输出前明确拒绝的零用量证据)完整零费用结算；其他超时、断开、取消或缺少完整用量继续保留 unknown 及预留暴露。服务拥有独立图片许可池，默认最多 2 个活动执行；等待最多 30 秒，超时 429 image_capacity_exhausted、Retry-After: 1，且不创建 intent/调用上游。许可由执行作用域持有，在成功、失败、取消、断开或关闭时幂等归还。图片许可与文本执行无共享许可计数，既有连接与 Key/全局账本限制仍适用。

非流式响应最多 48 MiB，原字节回传；200 且 data 至少含一个有效、非空 base64 b64_json 才判为结果成功。空 data/非 JSON 的 200 原样回传但结果记失败；超限为 502，未知责任保留。stream=true 时 SSE 原字节转发（包括注释、event 行、换行与 DONE），仅 image_generation.completed / image_edit.completed 加有效最终图片形成完成证据；预览、EOF 和 DONE 本身不授予成功。缺完成、提供者错误、畸形事件/图片或超限失败，不重放。SSE 单事件及总正文上限均为 48 MiB；此合成契约仍需真实提供者核对。

原生 Images usage.input_tokens/output_tokens 映射到 imageInputTokens/imageOutputTokens；可选 input_tokens_details.text_tokens/image_tokens 映射到 imageInputTextTokens/imageInputImageTokens。图片数按有效 data[].b64_json（SSE 完成事件的 b64_json 或 data）计数。无可信计数时对应指标不可用，不填零；费用按图片模型费率向上取整估算，缺全部 token 时费用不可用。缺完整用量保持 partial/unknown；结果成功与结清独立。当前 schema v11 的 usage JSON 保留图片计数；新增可选计数不回填历史。原生证据携带可选 nativeImages 标记，仅对此类记录隐藏不适用的宿主指标；旧 Images→Responses 记录的宿主用量保持可见。

Responses 托管 image_generation 工具仍单独解析和计量，图片 token 不加到宿主 token；宿主与工具费率分别估算后相加。工具模型缺省取部署默认值，须在 Key 有效 imageModels 内，对话模型须经 Key 授权并声明 imageGeneration。含图历史/图片工具可与 compact 和流式压缩组合；历史 image_generation_call 的 ID 仍须同主体/身份归属验证。图片内容与 prompt 不写入核心库。

每请求最多 32 MiB 正文；参考图最多 16 张，单图解码最多 16 MiB，参考图/mask 合计最多 24 MiB，单图最多 50,000,000 像素。multipart 转为 base64 后会增加正文大小，但仍受已验证图片总字节限制。反代 client_max_body_size 使用 33m。共享原始正文预算 48 MiB，超过 8 MiB 时 HTTP/WS 在缓冲前取得租约；预算不足不排队，HTTP 503 capacity_exhausted、Retry-After: 1，WS error 保持连接。读取结束、派发完成、失败、断开和超时归还租约；预算不代表进程 RSS 上限。

普通数据连接由dataConnections配置（默认128，8—1024），另有固定16条控制余量，WS 队列与任务限额仍见 P13/P14。HTTP 上传期限 10 秒，执行总期限默认 600 秒，可配置 1—1800 秒；首响应/进度空闲默认 30/60 秒，写入期限 5 秒。Responses 图片工具的上游单事件 8 MiB、总事件 32 MiB 上限保持。

离线迁移与备份见[Key 治理](key-governance.md)。合成协议检查与 Desktop/真实订阅兼容是不同证据；真实原生端点的字段、SSE 完成形状、用量及账号头要求须经部署后网关内验收。

## 相关文档

[文档导航](../README.md)
