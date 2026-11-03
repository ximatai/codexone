# 顺序验证与动态值审计

记录可复现验证、平台边界与请求动态字段来源。

## 范围

仅本地合成资料和 loopback 假上游，不使用真实订阅、提供者端点或部署环境。真实上游缓存命中验收仍待发布后维护者执行。验证平台为 macOS arm64、Apple Swift 6.4.2；未运行 Linux 构建。测试中的原始正文断言可在 Linux CI 执行，不依赖字典遍历顺序或 Foundation keyed encoder 顺序。

对象相等继续递归使用 Dictionary 语义，不依赖键顺序；未发现需要改为顺序敏感比较的现有调用点。

## 请求组装审计

- ResponseRequest 删除 reasoning 的 null 成员、text 的 null format/verbosity、null tool_choice/parallel_tool_calls；剥离本地 input 标签及 reasoning/compaction 的本地 id。托管图片工具按可信模型覆盖/追加 model。字段替换保留位置。
- codex-subscription 普通 Responses 固定 store=false、stream=true；字符串 input 变为 role/content 的 user 数组；受约束参数的 null 与 null service_tier/previous_response_id 删除。其他字段不新增随机值，compact 和图片保留既有独立契约。
- WS 下游 create 去除 type、stream_id、generate 并设置 stream=true；上游 public responses 去除 stream，订阅保留；追加 type=response.create，Lite 在 client_metadata 写入固定标记，订阅把已有 turn-state 写入 client_metadata，warmup 追加 generate=false，命名 lane 追加客户端 stream_id。自动 interrupt 按 type、response_id、可选 stream_id 固定顺序组装。未知控制和客户端 interrupt 原字节转发。
- 原生 Images：有 model 的 JSON 原字节；缺失 model 时追加可信默认模型；multipart 按收到的 part 顺序生成 JSON，图片收集后固定追加 images。无随机正文值。
- 后台窗口预热正文仅由模型、配置消息、固定指令/计数/能力选择构成，无时间戳或 attempt UUID。重置卡消费的 redeem_request_id 是合法逐操作 UUID（重试保留既有 intent ID），可选 credit_id 来自操作。OAuth 交换/刷新/设备轮询的 code/verifier/refresh_token/device_auth_id/user_code 来自授权状态，非生成正文；form 字段排序，JSON 字段改走同一有序 writer，消除旧哈希顺序。

## 会话头与逐请求动态值

- session_id/session-id/x-session-id、thread-id、conversation_id/x-conversation-id、允许的 x-codex-* 和扩展头保留客户端值（受容量、Connection 和安全规则过滤）；网关不生成随机会话 ID 或 prompt_cache_key。turn-state 来源于客户端或上游元数据，依原契约验证来源；订阅 WS 从握手移除该头，并在 create metadata 携带原值。
- 原生 UA/originator/version 保留；非原生由可信 ClientFingerprint 设置固定版本/OS/arch/terminal 和 originator。Host/Content-Type/Accept、Lite 头与缺省 WS OpenAI-Beta 由目标/模式确定。
- authorization 随所选账号与凭证刷新变化，chatgpt-account-id 随所选账号变化；这些已有行为未改。WS Sec-WebSocket-Key 每次握手随机，帧 mask 每帧随机，属于传输安全封装，不进入 JSON/提示；正文比较在解 mask 后进行。HTTP 长度等传输头由正文确定。
- 本地 attempt/request_id UUID、执行时钟、期限和路由健康仅用于内部协调、账本及客户端诊断/响应头；不注入生成上游 JSON 或会话头。提供者 response_id、客户端 lane/续接状态是合法逐 turn 值，取消/interrupt 引用当前响应。
- 本任务没有改动上述动态字段的生成/来源/值；只有对象布局确定化与过滤字段位置保留。TTL 白名单在独立提交，改变客户端可见明细，不影响生成正文或计量证据。

## 性能与验收记录

2026-11-03 本机定向结果：

- `swift build -j 12` 通过；`swift test -j 12 --filter jsonOrder` 的四项测试通过，含冻结旧实现的差分语料、原始字节/修改位置、错误和用量过滤顺序。
- `python3 scripts/verify_json_order.py --binary .build/debug/codexone` 通过两种契约 × 两种上游传输。每个组合重启一次、每条路由重复三次：共 84 次生成/compact 与 12 条原字节控制，检查多层工具 schema、上游正文一致、客户端 JSON/SSE/WS/compact 顺序与稳定会话头。
- `python3 scripts/check_docs.py` 通过 87 篇 Markdown；Swift 严格格式检查通过。
- `python3 scripts/benchmark_json_order.py` 用 `swiftc -O` 编译实际四个 JSON 源文件和冻结旧实现，合成正文 1,044,031 字节、400 个工具，预热一次后各 10 次解析加序列化均值：旧 25.7332 ms，新 26.2998 ms（约 +2.2%）。同一语料 debug 定向测试均值旧 43.3123 ms、新 104.6972 ms；逐字节 Swift 扫描/写出在未优化构建下较慢。计时受本机负载影响，不代表 Linux、端到端延迟或吞吐承诺。
- 独立 TTL 修改的两项测试通过：只放行指定非负整数，删除未知/畸形成员与非对象容器，并证明计量证据不变；二进制 JSON/SSE/WS 验收同时检查两个 TTL 计数和未知嵌套字段删除后的原始字节。
- `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 一次完整通过（退出码 0）：严格 Swift 格式、架构检查、12 jobs 构建、425 项 Swift 测试和 35 个后端脚本全部通过。覆盖取消、总/进展超时、断流、提供者错误、重启和存储失败。未重复运行通过的完整 backend 验证。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [验证](verification.md) · [协议](../../reference/specs/protocol.md)
