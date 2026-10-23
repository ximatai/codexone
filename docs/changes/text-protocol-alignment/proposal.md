# 文本协议基线与可信终态对齐

用户要求继续跟进优化。依据[复盘](../../evidence/protocol-alignment-review.md)、P06/P09/P11/P13/P15与U01/U02，先核对完整文本请求、响应和终态，不把CLI/合成结果代替Desktop或真实订阅。本轮范围为已选文本路径的兼容与责任边界，不改schema、账号路由、恢复或重放语义，不切换公开测试入口/旧服务。

## 固定依据与已确认差异

- 官方SDK修订`81792ff040a2ca2b70348163049d3d69d5ba95cf`的[Response](https://github.com/openai/openai-python/blob/81792ff040a2ca2b70348163049d3d69d5ba95cf/src/openai/types/responses/response.py)声明created_at为float、instructions为字符串/输入项列表/null、incomplete_details.reason可缺省/null；本实现分别限制整数/字符串/必有字符串，存在独立可复现的过度拒绝。尚未证明第五次实际失败具体命中了哪一项。
- 官方Codex修订`1c0c45bfc372fb7d7d581508fdef5eef8235eab7`的[流解析器](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/sse/responses.rs)按消费职责处理事件；[当前请求结构](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/common.rs)与已验固定CLI存在代际差异，不能借此宣称新版本兼容或无界接受所有新控制字段。
- 之前已实测的终态/status矛盾、total不一致、HTTP response ID不一致仍是缺口；见[可靠性核查](../gateway-reliability-audit/proposal.md)。本轮补三项明确屏障，仍分别保留正确归属的可信用量，不把输出失败当零消耗。

## 行为

1. 提供者created_at存在时接受JSON数值（包括小数），不转换、舍入或用于授权/计价；缺省沿用现行兼容，null/其他类型拒绝。instructions作为非执行性回显元数据，接受字符串/null或最多128项的对象列表；保留原结构，不从内部ID、引用、工具或usage授予权限/绑定/记账。其他类型拒绝，原JSON深度/事件/流总字节预算仍先执行。请求instructions仍按选定客户端的独立契约校验，不由响应兼容扩大输入执行能力。
2. incomplete_details非null时必须为有界对象，已知reason缺省/null/字符串均可；扩展元数据不参与结果/权限判断。incomplete仍失败结果，不由reason缺省转为成功。
3. response.status缺省/null沿用选定稀疏事件兼容；提供时须与已知事件对应：created允许queued/in_progress，in_progress仅in_progress，completed/failed/incomplete各自对应。矛盾为协议失败，有效usage先观察再拒绝。未知扩展不得冒充终态。
4. total_tokens存在时必须为非负有界整数；input/output都已知时要求相加一致。不修写、补零或以total反推出缺失输入输出；可信输入/输出计量与下游终态字段可消费性分别校验。
5. HTTP SSE在单次执行内，已知response对象及response_id必须与首次出现的response ID一致，隔离扩展不创建/改变ID；不额外要求稀疏流必须先created。身份冲突在观察该终态usage前拒绝；相同响应的其他对象/状态/输出校验失败仍保留已观察用量。WS保留其既有sole-reader关联/证据屏障，不为统一实现弱化它。
6. 普通响应单事件/JSON预算从256 KiB增至1 MiB，以容纳已允许的512 KiB请求中工具/指令回显及有界输出；总流仍8 MiB，图片预算和WS共享队列/期限不变。加入超过旧上限的合法回显及超过新上限的实际socket负向，不能只增请求上限而忽略最终事件大小。该包络仍是明确限制，不保证任意长输出都可容纳。

## 验收

先建立[协议矩阵](../../evidence/text-protocol-matrix.md)，明确接受/拒绝/适配/未验证。新增独立字面量事件与提供者脚本，不调用trial_provider.response_events生成被测响应；请求/响应双向观察，覆盖HTTP SSE/JSON、桥接/native WS、两轮完整窗口、合法元数据组合、非法类型、矛盾终态/总数、跨response的伪造usage、未知扩展无权，以及失败后持久责任/无重放/无正文日志。

主Agent定向验证、自查并提交，再运行受影响完整后端/Linux出口；没有证据不标完成。真实调用只在原授权的独立私有实例、既有代理、有效access快照和累计8次上限内进行，目前已用5次；首错停止，旧账全部引用保留，公开入口和旧服务不变。实际Desktop仍须另行操作证据。
