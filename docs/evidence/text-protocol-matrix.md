# 文本链路协议对照矩阵

核对日期：2026-10-23—24。固定来源与本地校验职责见下；现行行为以[协议规范](../specs/protocol.md)为准，验证见[摘要](text-protocol-validation.md)。全局状态只见[STATUS](../../STATUS.md)，本表不是部署或调用授权。

固定来源：[官方SDK Response](https://github.com/openai/openai-python/blob/81792ff040a2ca2b70348163049d3d69d5ba95cf/src/openai/types/responses/response.py)、[官方Codex请求](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/common.rs)与[流解析器](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/sse/responses.rs)、[CLIProxyAPI请求适配](https://github.com/router-for-me/CLIProxyAPI/blob/d946c4fba6fc9a5cfbca1f3d85184d62ad2fb683/internal/runtime/executor/codex_executor_request.go)。多轮视图参考[既有LiteLLM对照](gateway-reliability.md#g04第一轮成功不足以证明上下文一致)。这些源码读取不计外部项目测试通过。

| 链路/字段 | 本地入口/校验 | 外部依据/边界 | 决策及验收缺口 |
|---|---|---|---|
| 默认目录/模型/能力 | ModelCatalog/ModelProfiles/ClientTools | 固定CLI已有默认/显式目录及Lite全闭环；新主线不等于已验版本 | 保持；Desktop工具/新版本另验 |
| 认证与代理 | ResponsesDataService/UpstreamHTTPProxy | 服务注入身份；既有Clash实际200/正文/usage | 保持TLS、不继承下游凭证、不直连回退；池/刷新live未验 |
| HTTP stream/store | ResponseRequest/HTTPResponseExecution | 本地可JSON/SSE，订阅适配器存在强制stream/store规则 | 未证明所有下游组合获订阅支持；不因stream=true/store=false探针成功解除JSON/store兼容缺口 |
| 输出上限/采样/缓存/tier | ResponseRequest允许/透传 | CLIProxyAPI对部分订阅模式有删除/归一化规则，不能视为本项目承诺 | 不静默删除；需按后端/模型明确支持或准入拒绝，真实细项仍未验证 |
| 指令请求 | ResponseRequest字符串/null | 当前所选请求路径；最新官方请求结构已变化 | 保持当前输入范围，不由响应metadata扩大执行能力 |
| reasoning/null/上下文控制 | ResponseRequest | 已有明确SDK/固定CLI来源，选定枚举及null语义 | 保持；新主线字段/组合不自动开放 |
| Lite/namespace/function/custom | ClientTools/ClientInput | 已有实际固定CLI工具往返与默认Lite验证 | 保持数量/共享说明预算；内置搜索明确不支持，Desktop工具另验 |
| HTTP/WS握手与续接 | HTTPResponseExecution/WebSocketTurns | HTTP、桥接、native连接有不同寿命/隐式状态 | 不假定跨HTTP保持store=false缓存，不自动换传输/重放 |
| SSE媒体类型/字节/期限 | SSEDecoder/HTTPResponseExecution | 真实观察缺头；已补有界兼容 | 保持JSON/HTML/截断/超量拒绝，不以保活或扩展延长进度 |
| 非语义扩展 | ProviderObservation.isIsolatedExtension | 官方未处理事件无业务输出；真实已观察隔离 | 保持整条隔离，不读取ID/usage/终态，不扩展工具授权 |
| response ID/previous ID | ProviderObservation/WebSocketTurns | WS与HTTP均有执行内关联 | 校验HTTP一致性，先关联再信任终态usage；previous仍须匹配已授权请求 |
| status/事件 | ProviderObservation/ExecutionObservation | 终态语义及已有矛盾探针 | 按显式对应表校验，允许既有稀疏缺省/null，矛盾失败不丢已知用量 |
| created_at | ProviderObservation | 官方类型为float | 接受JSON数值；不改变时钟、计价或归属 |
| 响应instructions | ProviderObservation | 官方字符串/输入项列表/null | 作为有界对象列表保留，不提取内层权限/绑定/usage |
| incomplete_details.reason | ProviderObservation | 官方类型允许缺省/null | 允许可空已知成员和有界元数据；incomplete仍非成功 |
| response.tools/background/外部对象 | ProviderObservation | 本地未开放能力与执行控制 | 继续严格；不能以metadata兼容放过实际未授权工具/后台/外部对象服务 |
| message/phase/part | ProviderObservation.itemBindings | 既有nullable及reasoning_text独立修正 | 保持已知内容类型/容量；新成员需分类，不全量放过 |
| 逐项与最终output | ProviderObservation/StreamCompaction/WebSocketTurns | 压缩有窗口一致性，普通窗口仍有已复现缺口 | 不声称全部视图已对齐；须区分合法快照差异与ID/type/call_id冲突，再单独补统一关联 |
| input/output/cached usage | observeUsage/ProviderObservation.usage | 核心累计证据与结果独立；真实计量见责任账 | 保持完整/部分/缺失分类，不能将输出失败当零或丢已有证据 |
| usage附加元数据 | ProviderObservation.validateUsageContainer | 固定诊断及官方新增属性兼容约定 | 已知计量严格/metadata有界隔离且输出投影已支持字段；原始具体字段未留存，不能认定唯一子原因 |
| total_tokens | ProviderObservation.validateUsageContainer | SDK客户端消费字段 | 验证类型/范围/已知计数相加一致，不补零/反推计量 |
| 工具/推理/压缩回传 | ClientInput/opaqueContext/StreamCompaction | 完整与增量窗口/相同身份均需验证 | 保持密文仅指纹绑定；不能由文本两轮外推全部工具/压缩 |
| EOF/取消/error/failed/incomplete | 执行owner/ExecutionObservation | 原无终态unknown；usage与业务结果独立 | 保持首错停止/无自动重放，进一步错误消费矩阵仍保留 |
| 诊断与持久账 | ProtocolFailureDiagnostics/Runtime finalizer | 固定对象/阶段分类；不记录正文或任意字段 | 按固定分类记录；历史责任见[调用账](real-subscription-validation.md) |

矩阵描述所选契约及证据边界，不是全部能力已实现/通过的声明。正向样例必须独立于本项目提供者生成器，并与负向安全、持久账本及原回归同时验；真实两轮和实际Desktop分别验收。
