# 图片原生透传

日期：2026-10-30。替换 Images 入口现有的“改写为 Responses 强制图片工具”适配层，改为转发到提供者原生 Images 端点。前置变更：[Desktop 图片闭环对齐](../desktop-image-parity/proposal.md)。

## 依据

- Codex 客户端源码（openai/codex `codex-rs/ext/image-generation`、`codex-api/src/endpoint/images.rs`）：内置 `image_gen.imagegen` 是本地工具，直接 `POST {provider base_url}/images/generations|edits`。请求为非流式 JSON：`prompt`、`model`（固定 `gpt-image-2`）、`background`、`quality`、`size`；编辑另带 `images: [{"image_url": "data:..."}]`，最多 5 张，来源为引用文件或会话中最近的图片。响应读取 `data[].b64_json` 和可选的 `generation_id`、`background`，并读取响应头 `x-codex-imagegen-request-id`。用 ChatGPT 登录直连时，地址就是提供者的 `/backend-api/codex/images/*`。客户端测试已断言它不再声明托管 `image_generation` 工具。
- 同类项目（OmniRoute `codexImages.ts`、opencodex WP1、cc-switch）在生产中直接转发到该原生端点：账号 Bearer、`chatgpt-account-id`、Codex 客户端头；只请求一次、不自动重试；状态与正文原样回传；成功响应含 `usage`。
- 旧服务的适配层持续出问题：
  - 宿主模型选择导致生图全部失败（Soju06/codex-lb#2134，PR #2537）；
  - 本地参数矩阵落后于提供者（透明背景 PR #2593、新图片模型 #2304）；
  - 媒体请求挤占对话容量（#1414）。
- 2026-10-30 尝试在网关外直接用账号凭证探测原生端点，因违反凭证边界被拒。本变更以网关内正式路径完成首次真实验证。

## 新契约

1. **路由**：`/v1` 与 `/backend-api/codex` 下的 `POST images/generations` 和 `POST images/edits` 都转发到所选账号提供者的 `/backend-api/codex/images/generations|edits`。
2. **请求**：
   - JSON 正文按原字节转发，只读取 `model` 与 `stream`；缺 `model` 时插入部署默认模型，此时需要重新序列化。
   - `/v1` 的 multipart 编辑转换为原生 JSON：`images[].image_url` 用 data URL，`mask` 为 `{"image_url": ...}`，文本字段按原类型写入。
   - 网关不再校验尺寸、质量、背景、格式、透明度、fidelity、`n`，这些交给提供者判定，错误按 P27 透传。
   - 保留的网关职责：请求体上限与全局预算、参考图须为内联 PNG/JPEG/WebP（不抓取远端 URL）、单图与合计字节上限。
3. **权限**：`model` 必须在部署图片模型列表中，且在 Key 的有效 `imageModels` 内，否则 403 `model_not_allowed`。视觉权限不适用于参考图。
4. **头部**：
   - 转发客户端的 `x-codex-image-turn-id`、`x-codex-turn-metadata`，以及与 Responses 路径相同策略的客户端标识头；网关注入账号认证头。
   - 回传提供者的 `x-codex-imagegen-request-id` 和网关 request_id。
5. **执行治理**：
   - 一次操作一个持久 intent，派发前完成归属。
   - 账号选择沿用现有路由；只请求一次，开始发送后不切账号、不重放。
   - 客户端断开、超时或结果不完整时记为 unknown，保留预留暴露。
   - 执行总期限默认 600 秒（可配置）。
6. **图片并发舱壁**：
   - 全局并发图片执行默认上限 2，可由池配置 `imageConcurrency` 在 1–8 之间设置。
   - 超出时最多等待 30 秒；仍拿不到许可则返回 429 `image_capacity_exhausted` 并带 Retry-After。
   - 许可在成功、失败、取消和下游断开时都必须且只释放一次；不占用文本对话容量。
7. **响应**：
   - 非流式：上限 48 MiB；200 且至少一个非空 `data[].b64_json` 时才算成功，否则记失败并原样回传。
   - `stream: true`：按提供者 SSE 原样转发，只以可信的完成事件与有效图片判定成功。
   - 用量取 `usage`（含 `input_tokens_details` 中的图片/文本细分）映射到既有图片指标；没有可信用量时记为不可用，不填零。
   - 图片内容与 prompt 不写入核心库。
8. **配置**：
   - `imageGeneration.models[]` 只需 `id` 与费率。`hostModel`、`sizePolicy`、`supportsTransparency`、`supportsInputFidelity` 为兼容字段：可出现，但不再生效。
   - `defaultModel` 不变。
   - Responses 托管 `image_generation` 工具路径保持上一变更的权限语义。
9. **删除**：Images 入口的 Responses 改写、图片工具强制调用、本地参数矩阵，以及只为它们存在的回复翻译代码。Responses 图片工具的解析与计量保留。

## 不变项与排除

不实现 `n>1` 扇出、URL 抓取、文件托管、variations；不改 schema（沿用图片 intent/计量字段）；不改 Responses 托管工具的计量。Desktop 辅助控制接口（`alpha/search`、`memories/trace_summarize`、`realtime/calls` 等）另立变更。

## 验收

- 合成上游：
  - 生成和编辑请求的路径、头部、正文按原字节到达；缺 `model` 时补默认值。
  - multipart 编辑转换后的 JSON 正确。
  - 未授权模型返回 403，且不派发。
  - 提供者的 400/429/5xx 按 P27 透传，429 触发账号冷却。
  - 成功响应计量正确；缺 `usage` 时记为不可用。
  - 空 `data`、非 JSON、超过 48 MiB 都判为失败。
  - 流式路径正确。
  - 下游断开记为 unknown 且不重放。
  - 舱壁等待、429 和许可释放（含断开）正确。
- `verify_images.py` 改为覆盖以上原生路径；`/v1` 与 `/backend-api/codex` 两个前缀都测。
- 部署后真实验证（已获授权）：
  - 通过网关生成 1 张、编辑 1 次，均用 low 质量，核对端点、头部、`usage` 与账本。
  - 由用户在 Desktop 中生成并编辑图片。
