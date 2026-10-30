# Desktop 图片闭环对齐

日期：2026-10-30。用户目标：Desktop 使用本网关与使用标准 Codex 服务无感一致，包括图片生成/编辑及含图会话的长期使用。2026-10-30 真实 Desktop 已通过文本、视觉输入与工具验收（见[开放协议透传验证](../open-protocol-passthrough/verification.md)），图片生成尚未开放。

## 依据

- 旧服务只读记录：Codex Desktop 的生图全部走 HTTP `POST /backend-api/codex/images/generations` 与 `/images/edits`（JSON，参考图为 `images: [{"image_url": "data:..."}]`），公开模型为 `gpt-image-*` 族；数百次成功，平均耗时约 2 分钟。Desktop 不在对话中声明 Responses `image_generation` 工具。
- 旧服务对 Images 请求忽略未知字段，不限制参考图数量与单图大小，仅受总请求体上限（解压后 32 MiB）约束；内部宿主模型为固定候选，不要求等于任何对话模型。
- 本网关现状与之冲突的约束：
  1. 含视觉输入或图片工具的 compact / 流式压缩在派发前以 `unsupported_image_compaction` 拒绝。用户在含图会话中达到自动压缩阈值时会话失败，影响已上线的视觉功能。
  2. Images 请求的未知顶层字段（如 `user`）与参考图对象的额外成员一律拒绝。
  3. 全数据面请求体上限 8 MiB；参考图最多 4 张、单图 4 MiB、合计 6 MiB。高分屏截图作为参考图会被拒绝，含多图历史的会话也会触顶。
  4. Responses `image_generation` 工具要求本次对话模型等于图片映射的 `hostModel`，每个图片模型只能在一个对话模型下使用。

## 新契约

1. **压缩**：删除图片/视觉与 compact、流式压缩组合的派发前拒绝。授权不变：任何位置的 `input_image` 仍要求视觉权限，声明图片工具仍要求图片权限；压缩不新增网关的图片执行或计量。`unsupported_image_compaction` 从诊断码中移除。
2. **Images 字段**：已知参数（model、prompt、n、size、quality、background、output_format、output_compression、moderation、input_fidelity、partial_images、stream、response_format、images、mask）按现有映射校验；其他顶层字段丢弃，不转发、不报错。参考图与 mask 对象必须含字符串 `image_url`，其他成员丢弃。
3. **大小上限**：
   - 单个请求体（HTTP JSON/SSE、multipart、WS 单条消息）上限 32 MiB。
   - 参考图最多 16 张，单图 16 MiB，参考图与 mask 合计 24 MiB；单图像素不超过 50,000,000，不再设总像素上限。
   - 新增全局请求体字节预算 96 MiB，由所有正在读取或持有请求正文的 HTTP 请求与 WS 消息共享。超过 8 MiB 的正文在读取前按 Content-Length 或增量申请预算；预算不足时有界拒绝：HTTP 返回 503 `capacity_exhausted` 并带 Retry-After，WS 返回 error 帧且连接保持。正文释放后归还预算，不排队等待。
   - 上游图片事件上限（单事件 8 MiB、总计 32 MiB）不变；超限仍为明确失败。
4. **Responses 图片工具**：只需满足两点：图片模型在 Key 的 `imageModels` 中，且本次对话模型是 Key 授权的、声明了 `imageGeneration: true` 的模型。`hostModel` 只用于 Images 入口选择内部宿主。部署配置仍要求每个图片映射的 hostModel 声明了 `imageGeneration`。
5. **部署模板**：数据入口反代 `client_max_body_size` 与新上限一致（33m），同步 [TLS 反代](../../development/tls-proxy.md) 与[图片入口](../../development/images.md)。

## 不变项与排除

不改 n=1、只回 base64、不抓取远端 URL、不提供文件托管；不改图片计量/估算、持久 intent、一次操作一个执行、不重放语义；不改账号路由与 schema。数据面连接上限（8）另立变更评估。真实图片调用须用户另行授权。

## 验收

- Swift/socket：
  - 含 `input_image` 的历史可进行 `/responses/compact` 与流式压缩（HTTP、WS）；无视觉权限时仍以 403 拒绝。
  - Images 请求带未知字段（如 `user`）与参考图额外成员（如 `detail`）时成功，转发的工具声明中不含这些成员。
  - 16 张参考图且合计未超 24 MiB 时成功；超过任一上限时在派发前拒绝。
  - 约 20 MiB 的 Responses 请求经 HTTP 与 WS 均成功；超过 32 MiB 时 HTTP 返回 413，WS 返回 error 帧。
  - 全局预算耗尽时返回 503 `capacity_exhausted` 且不派发；正文释放后预算恢复。半截上传、客户端断开与读取超时都会归还预算。
  - Responses 图片工具在两个不同的授权对话模型下都可用；图片模型未授权，或对话模型未声明 imageGeneration 时拒绝。
- Linux verification 出口；部署后由用户在 Desktop 完成生成、参考图编辑，并在含图会话中触发压缩。
