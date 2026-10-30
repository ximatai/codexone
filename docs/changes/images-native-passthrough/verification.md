# 图片原生透传验证

日期：2026-10-30。平台：macOS arm64，Apple Swift 6.4.2。全部上游为本机无真实凭证合成服务；没有真实生成、部署、推送或提交。

## 验收覆盖

| 入口/责任 | 证据 |
|---|---|
| 两前缀 generations/edits、方法、固定原生路径、原字节和未知字段、补默认 model | `scripts/verify_images.py`；池 HTTP socket 测试同时核对原文及所选账号认证 |
| multipart 的 images/mask、文本/数字/布尔、仅 /v1 edits | `verify_images.py` |
| model 未授权 403、无 intent/上游调用 | `verify_images.py`；图片权限原子准入测试 |
| 客户端元数据与账号头隔离、提供者 request ID | 单身份脚本及 `AccountPoolHTTPTests`；提供者错误也检查图片 request ID |
| 400、429、500 按 P27 映射与脱敏，不重放 | `verify_images.py`；池 429 测试确认选中账号冷却，剩余账号禁用后无新派发 |
| JSON 原字节、200 空 data/非 JSON 记失败、超过 48 MiB 拒绝 | `verify_images.py`；结果和可信用量完整度独立 |
| 原生 SSE 的注释、event 行、CRLF、DONE 原字节；完成/缺终态/空图/错误 | `verify_images.py`，两前缀两操作；对话上游配置为 HTTP/WS 时图片均只走 HTTP |
| usage token 与明细、有效图片数、按图片费率估算、缺失指标为空 | 脚本检查持久账本；`UsageQueryTests` 检查明细/聚合、费用 null 和旧宿主证据兼容 |
| 下游在上游返回前关闭，unknown、无重放、释放许可 | 真实 socket held 请求；释放后下一请求完成 |
| 并发 1 占满、实际等候 30 秒后 429/Retry-After、无新 intent/上游调用 | `verify_images.py`；Swift 另外覆盖取消等待与重复释放不增加许可 |
| 旧配置兼容、可省略旧字段、imageConcurrency 默认与边界/未知字段 | `ImageConfigurationTests`；单身份及账号池校验 |
| Responses 托管图片工具保留权限、归属及独立计量 | 脚本 HTTP/WS、池 HTTP/桥接/原生 WS 测试及既有权限测试 |

原生 usage 采用新增可选 JSON 指标和 nativeImages 标记，数据库表/列及 user_version 不变。标记只用于新原生记录的统计投影，旧图片适配器的宿主 token 继续可见；缺失历史明细不回填。

## 命令结果

| 命令 | 退出码/关键输出 |
|---|---|
| `swift build` | 0，`Build complete!` |
| `swift test 2>&1 | tail -20`（保留 Swift 进程退出码） | 0，四个 target 的 35/37/3/138 项，共 213 项；尾行 `Test run with 138 tests in 1 suite passed` |
| `./scripts/verify.sh --backend` | 0，包含存储/恢复/账号/HTTP/SSE/WS/代理/图片/Key/管理/配置/迁移全部合成验证；图片 HTTP/WS 两配置均输出 `PASS: native Images byte/header/path parity, multipart, usage, SSE, provider failures, unknown/no replay and capacity` |
| `swift format lint --strict --recursive Sources Tests Package.swift` | 0 |
| `python3 scripts/check_docs.py`、`git diff --check` | 0；159 篇文档检查通过，无差异格式错误 |

完整出口的 Swift 阶段覆盖 212 项；随后只增强了池请求断言、增加单身份配置测试并同步文档，独立 `swift test` 的最终 213 项全部通过。执行代码没有在完整出口通过后变更。独立原生图片脚本也曾单独以退出码 0 通过。

SwiftPM 在此受限环境的 manifest sandbox-exec 不可用，原始不带覆盖的首次 `swift build` 退出 1；按 brief 使用仓库外临时 swift 包装器，仅为 build/test/package 注入 `--disable-sandbox`，以上成功命令均通过该包装器执行，不改依赖或验证脚本。现有本地依赖镜像 identity 冲突的 SwiftPM 警告仍存在，未修改 Package 文件。

首轮完整出口在代理合成测试启动一个网关子进程时报告启动失败；随后固定最终二进制重跑。未将失败归因为已确认的产品缺陷或平台原因。

## 真实端点待核对

- 所选账号/模型是否实际支持原生路径、请求字段，以及客户端标识头的必要集合；未知字段/参数由提供者判定的实际错误形状。
- 原生 edits 的 images/mask data URL 形状、模型默认值和真实图片数量/格式边界。
- SSE 是否支持 stream=true，完成事件是否确为 image_generation.completed / image_edit.completed，最终图片和 usage 位于何处，结束/取消语义是否相符。合成完成形状是实现假设，不是真实兼容证据。
- usage.input_tokens/output_tokens 与 text_tokens/image_tokens 的实际提供情况、语义和缺失行为；本地费率仅为估算，不代表订阅账单。
- x-codex-imagegen-request-id 的实际可用性，429/Retry-After 的冷却行为，真实生图耗时与首响应/进度期限。

## 主 Agent 复核与真实验证（2026-10-30）

- 本机重跑 `./scripts/verify.sh --backend`：退出码 0，Swift 共 213 项通过（35/37/3/138），合成脚本输出 87 条 PASS。
- Linux amd64 镜像构建与 `verification` target（含 `verify_images.py`）：退出码 0。
- 测试部署（账号池、WebSocket 对话上游；图片模型 `gpt-image-2`，并发 2；反代正文上限 33m），临时 Key，客户端 UA 为 Codex 形态：
  - `/backend-api/codex/images/generations`（JSON，1024×1024，low）：200，耗时约 105 秒；1 张图片；回传 `x-codex-imagegen-request-id` 与 `x-request-id`；usage 含 `input_tokens_details.text_tokens/image_tokens` 与 `output_tokens_details`；
  - `/v1/images/edits`（multipart，以上一步的图片作参考图）：200，耗时约 138 秒；参考图计入 `image_tokens` 1536；
  - 账本：两次均为 settled/succeeded/complete，图片数与 token 细分和响应一致；Images 不适用的宿主 token 为 null。
- 已核实的真实端点行为：原生路径、data URL 形式的 images、usage 位置与细分、请求 ID 头都与实现假设一致。原生响应还含 `background`、`output_format`、`quality`、`size`、`safety_identifier` 等成员，网关原样透传。
- 发现：客户端 UA 为 `Python-urllib` 时，提供者在 2 秒内返回 403（网关记为 `upstream_rejected`），换成 Codex 形态的 UA 后成功。Codex CLI/Desktop 发送自身的 UA，不受影响。非 Codex 客户端（如 OpenAI SDK）是否需要网关代填 UA 待用户决定，未做额外探测。
- 该 403 在账本中按“无用量证据的失败保留 unknown 责任”的现行规则记为 unknown；规则本身属于独立的治理议题，不在本变更内修改。
- 仍未核对：SSE（`stream: true`）的真实事件形状，以及 429/Retry-After 的冷却行为。

