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

同时核对容量文档：图片配置已明确8条全局连接及8 MiB WS共享队列，现有实现与该配置一致；P13/P14仍遗留M2的32连接、512 KiB传输聚合/1 MiB队列说明。仅更正这几处规范文字，区分传输最大包络与普通请求512 KiB/响应1 MiB消费限制，不改变实现容量或以此声称弱宿主O14完成。

## 完整响应后的收尾窗口

修正探针后完整Linux出口再次复现：HTTP JSON客户端已读完整正文，第三笔仍settled/failed、failure=indeterminate，usage完整；故不能将问题仅归因提前停服。当前JSON头/正文/end三次独立异步写入，客户端按Content-Length合法读完后可关闭；且成功结果直到带期限任务组收尾后才记入，存在完整终态与迟到传输关闭竞争。改为同一有界writer sequence提交JSON三个部分（沿用5秒写期限和背压，不忽略写错）；所有Responses路径仅在响应已验证、绑定并成功提交完整终态后同步观察成功，不等待期限任务组收尾。已有failed/incomplete观察优先，写入前/写入中失败不观察成功；不把usage、item.done或未完成文本视为成功，不提前宣称客户端收到/执行工具。Core既有first-observation及finalizer语义不改，迟到关闭不能改写已提交的结果。

新增固定JSON写入失败诊断，不记录原异常或内容；实际快速关闭、部分输出取消、故障与正常停服均需回归。若再次失败继续停止真实调用，不能仅重跑到绿或放宽账本断言。

## 用量字段与附加元数据分责

本轮第六笔真实调用固定诊断为upstream_usage_container，已可信输入51/输出11且settled/failed；没有保留原始响应，不能断言是哪个附加字段或容量触发。复查发现原校验把所有usage成员都限制为数字或一层数字对象，与[官方兼容约定](https://developers.openai.com/api/reference/overview#backwards-compatibility)允许新增响应属性不相容，也没有区分计量字段和非执行metadata。

改为usage非null须为最多32成员的对象；input_tokens_details/output_tokens_details非null须为最多32成员的对象。input/output/cached继续由原证据解析严格验证，total继续独立一致性校验；已知cache_write_tokens/reasoning_tokens非null须为0—1000000000整数。普通纯文本路径的其他成员仅在内存中作为不透明元数据接受，输出只保留input/output/total及cached/cache_write/reasoning明细，其他成员移除；图片和独立compact仍沿原严格契约，受原JSON深度/单事件/总流预算限制，不递归提取ID、usage、权限或计费。只新增固定的根类型/根容量/明细类型/明细容量/已知明细计数诊断，不记录键名、值或原响应。独立样例覆盖附加字符串/布尔/嵌套元数据、不授予伪造绑定或计量，以及已知明细错误/超量拒绝并保留已可信计数。真实预算累计现6/8，仍首错停止，不因本次失败自动重放。

## 验收

先建立[协议矩阵](../../evidence/text-protocol-matrix.md)，明确接受/拒绝/适配/未验证。新增独立字面量事件与提供者脚本，不调用trial_provider.response_events生成被测响应；请求/响应双向观察，覆盖HTTP SSE/JSON、桥接/native WS、两轮完整窗口、合法元数据组合、非法类型、矛盾终态/总数、跨response的伪造usage、未知扩展无权，以及失败后持久责任/无重放/无正文日志。

主Agent定向验证、自查并提交，再运行受影响完整后端/Linux出口；没有证据不标完成。真实调用只在原授权的独立私有实例、既有代理、有效access快照和累计8次上限内进行，目前已用6次；首错停止，旧账全部引用保留，公开入口和旧服务不变。实际Desktop仍须另行操作证据。
