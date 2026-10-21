# RC-1：完整结果取回契约草案

这是拟验证的私有扩展方案，不是已存在的标准或 Codex 原生能力。进度/证据只见 STATUS。若目标客户端不具备所需能力，应沟通调整方案，而非把 unavailable 当作首发恢复功能完成。

## 目标与验证表

| 项目 | RC-1 工作方案 |
|---|---|
| 首个验证客户端 | 计划验证客户端 `codexone-recovery-fixture/1`，在本地合成上游走真实 HTTP 入口 |
| 验证模式 | 非流式 Responses 完整 JSON 取回；只取一个已完成执行，不拼接输出、不执行工具 |
| 候选入口 | 同一个 `POST /v1/responses` 的显式 recovery 请求；不增加历史列表/搜索/任意对象 GET |
| 关联 | principal + core generation + 客户端生成的 operation UUID；与原 attempt 原子关联 |
| 原请求 | 携带 `X-CodexOne-Operation`、`X-CodexOne-Core-Generation`；仍是合法 Responses JSON |
| 显式取回 | 同一入口/关联头，加 `X-CodexOne-Recovery: complete-result`，空 body；由网关在普通 Responses body 校验前识别 |
| 返回 | 同一次执行已封存的完整 JSON，标 `X-CodexOne-Replayed: true`；不暗示模型重新执行 |
| 消费方式 | 支持该扩展的客户端将结果作为整份结果取回/替换，绝不作为 token delta 追加或自动工具执行输入 |
| 原生 Codex CLI | 必须另核对实际版本和重试/头部/恢复消费契约；不能由 fixture 推导兼容，不假定存在隐式恢复能力 |

上述头名及路由语义是可调整草案，未经契约测试与目标客户端确认不作为公开兼容承诺。SSE/WS 断点续播、Images 结果和工具调用重放不纳入 RC-1，扩展时另写具体验收；正文缓存本身可以存这些内容，但“可保存”不等于“支持恢复”。

## 关联与去重规则（RC01）

扩展头必须按允许组合校验；未知 recovery 值、缺少关联头或普通请求混入不合法恢复 body 必须本地拒绝，不能透传到上游。

- operation UUID 只是关联，不是凭证。每次请求认证本地主体；generation 是主库代际，不是上游账号或秘密。
- 原请求提供 generation 前，已认证客户端可收到本地 `409 recovery_generation_required` 与当前 generation 响应头；该挑战不得 dispatch 或生成预留。过期 generation 必须拒绝，不能自动拿旧 operation 换代重试。
- 原请求在准入事务内唯一绑定 `(principal, generation, operation)`、规范请求指纹和 attempt；并发争抢仅一个可 dispatch。主体、端点、模型/工具策略及绑定证据不得因重试改变。
- 已使用 operation 的普通重复 POST 必须返回 `409 operation_already_exists`；内容不同返回 conflict，不再次执行。显式 recovery 只能读取已有 attempt，未知 operation 返回 unavailable，绝不转为生成。
- 不带这些扩展头的普通合法 POST 仍按新执行处理，不按正文指纹判重。操作标识的已用记录随主账本/必要 tombstone 保留，不能因为正文 TTL 到期就重新允许执行。主库恢复换 generation，旧关联一律无效。

## 成功与失败（RC02）

- 只有当前权限仍允许原操作、归属/generation 匹配、可信终态已观察、完整 JSON 已封存、正文未过期且不存在工具副作用重放语义时，才可取回。
- active/unknown terminal：`409 execution_in_progress_or_indeterminate`；缓存缺段/不可用/过期：`409 recovery_unavailable`；格式不合法：400；当前 Key 无权：403。外部不存在/跨主体关联统一不给存在性提示，按 unavailable 处理。
- 返回同一 response ID 及已记录 JSON，不再次创建 attempt、调用上游、计算新生成用量。恢复读取仍计请求速率/字节与并发资源，不能无限免费读取绕过容量。
- 网络发送完成不证明客户端收到；RC-1 采用显式整份取回，因此不需要猜最后一个已收 token。若客户端只能追加或自动执行工具，不得把 RC-1 接到其自动重试路径。
- 取回正文前须满足缓存规范的代际/授权屏障。删除/紧急撤销与读取并发时，取消后续读取并拒绝后续分块；已发给客户端的字节无法撤回，不宣称删除可追回已交付内容。

## 验证与首发门槛（RC03）

先用本地 fixture 证明：初始 POST 仅执行一次 → 上游完整终态已到达、客户端在结果交付时断开 → 有界持久化工作完成封存 → 显式取回同一结果。断连仍按普通前台取消/关闭处理，不为 RC-1 新增后台生成；终态尚未观察或正文未封存则必须 unavailable/indeterminate。

同时覆盖 operation 并发重试/不同 body、主体/权限变化、缺段、工具结果拒绝、TTL、重复读取、generation 变化、缓存故障，以及不会因 unavailable 触发新生成。成功路径和拒绝路径都走真实 HTTP 与临时两库，不以单个 helper 测试代替。

M3 出口必须至少有一种实际可使用的、明确客户端/版本与调用方式的恢复路径。fixture 只证明设计，不代替真实产品路径；显式恢复客户端若需作为产品能力提供，应先与用户说明调用方式/代价，更新范围草案，不能自动变成新的公共历史 API。目标客户端无可行契约是需要及时沟通的业务困难，不是可以隐藏的实现细节。
