# 开放协议透传：只约束网关自身职责

日期：2026-10-26。用户要求统一复盘 Desktop 迟迟不能验收的原因并修复；本提案改变 P15、P08 部分容量及 [兼容取舍](../../decisions/compatibility-policy.md) 中“未知成员/错误类型继续拒绝”的方向。

## 复盘结论

客户端请求与上游响应都按封闭允许集合校验，集合外字段、条目、事件或工具一律拒绝。协议由客户端与提供者持续演进，CodexLB 采用 extra=allow 式透传才稳定可用；本项目把每次真实差异变成一次“诊断→部署→请用户重试→放行一个字段”的循环，不能收敛：

- 真实订阅9次生成中7次失败，几乎每次不同形状（媒体类型、未知事件、未知对象、usage 容器、tools 回显策略）；Desktop 首次长说明拒绝同理。
- 上游响应校验发生在执行之后：合法生成被改写为502并留下 unknown/failed 账，用户看不到结果但额度已消耗。
- 提供者 `response.failed`/WS `error` 被替换成通用 `upstream_execution_failed`/`invalid_upstream_turn`。Codex 依赖 context_length_exceeded（自动压缩）、rate_limit 重试等待、usage_limit_reached、insufficient_quota 等原错误码决定行为；替换后客户端只能盲目重连（Desktop 截图“重连5/5”）。
- 对照 [Codex models.rs](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/models.rs) 与 [SSE 处理](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/sse/responses.rs)，日常 Desktop 使用必然出现而当前拒绝的形态：web_search/tool_search 工具；数组形式的 function_call_output（view_image、MCP 图片）；历史中的 web_search_call、local_shell_call、tool_search_call/output、agent_message；message/function_call 的 encrypted_content 与 metadata passthrough 字段；带 annotations 的输出；单响应超过16项输出；response.metadata（turn-state）被丢弃。
- 长会话必然越过的本地硬限：文本请求512 KiB、input 256项、每次请求引用32个（历史中每个 call_id 与每段加密推理都计为必须已绑定的引用）、单图请求最多4张、每 attempt 绑定32个。旧服务迁来的会话因引用未在本库绑定而直接 unknown_or_ambiguous_object。
- 合成夹具按网关自身假设构造，只证明实现与自身一致；真实 Desktop 与真实订阅从未组合验证。

## 新契约

原则：默认原样转发；网关只对自己承担的职责做严格校验——认证与 Key/模型/图片权限、请求与事件的字节/期限/并发上限、能检索服务端状态的引用归属、执行账本与可信用量、主体/账号隔离。

### 客户端请求

- 未知顶层字段、未知 input 条目类型、未知内容 part 及任意工具声明（含 web_search、tool_search、mcp 等内置工具）透传，由上游判定。仍拒绝：background=true；能读取服务端状态而无法证明归属的 `conversation`/`prompt`；非字符串 model；store/stream 非布尔；订阅后端已知不支持的显式参数（max_output_tokens 等，派发前400）。
- 图片：顶层唯一 image_generation 工具仍走现有权限映射，Lite 包或 namespace 内声明仍拒绝；任何位置出现 input_image（含工具结果数组）即要求视觉权限。仅图片编辑 mask 需要解码校验首图；取消4张/总像素限制，由请求字节上限约束。
- 硬引用只包括 previous_response_id 与 item_reference：须已绑定到当前主体/身份，否则拒绝（不变）。call_id、加密 reasoning/compaction 指纹、其他条目 ID 改为路由提示：已知时用于账号池亲和，未知或属于其他主体时忽略，不再拒绝，也不计入32个硬引用。加密内容只能由其所属上游账号解密，不构成跨主体读取。
- 文本请求上限由512 KiB提升为与传输聚合相同的8 MiB；取消 input 256项、64声明及512 KiB说明预算（由总字节约束）。现有剥离本地 message/输出/完整加密条目 id 的规则保持。

### 上游响应

- 只提取证据：response ID、条目 ID、call_id、reasoning/compaction 指纹、已知用量计数和终态。未知字段、条目类型、part、annotations、状态值、tools/policy 回显、previous_response_id 回显、输出项数均不导致失败；不再做语义摘要关联（OrdinaryOutputViews）与流式压缩一致性强校验。
- 未知事件原样转发给流式客户端（不授予归属、用量或终态权）；WS 轮外事件忽略，不再关闭连接；事件可引用未通告的 item。
- 已知计数畸形时不产生用量证据并记录固定诊断，不改写已生成输出；仍不把未知嵌套计数加入账本。绑定已存在于同一主体/身份时视为幂等，单 attempt 绑定上限提升到1024，超过后跳过后续提示绑定。
- 提供者错误透传为脱敏错误：保留 type/code/param/message/plan_type/resets_at/resets_in_seconds，message 中 org-/user-/proj-/acct 标识和邮箱替换为占位符，附加网关 request_id。HTTP 非200 使用对应状态（401 仍映射为网关502，上游5xx 映射502/503），WS `error` 事件结束当前 turn 并以带 status 的 error 事件或 HTTP 错误返回；response.failed 作为终态原样下发（其中 error 同样脱敏）。账号健康分类与 cooldown 继续按原错误码。

## 不变项与排除

主体/Key/账号隔离、准入事务、预留与结算、unknown 责任、不重放、P14 连接/lane 边界、事件1 MiB/执行8 MiB上限、图片独立契约、管理面均不变。本变更不新增恢复缓存，不改变 schema，不进行真实订阅调用或部署；真实验证另经用户授权。

## 验收

- 单元与 socket 测试使用按 Codex 源码实际结构构造的请求/响应样本：上述每种此前被拒的形态在 HTTP JSON/SSE、桥接、原生 WS 下成功转发，账本 settled，引用/提示行为符合上文。
- 提供者 failed/error/429/400 在三种传输下以原错误码到达客户端且无原始标识；账号健康仍按类别记录。
- 硬引用跨主体仍拒绝；未知提示不拒绝；池路由在提示已知时保持账号亲和。
- 受影响 Swift 测试与后端脚本更新为新契约后 `./scripts/verify.sh --backend` 通过；删除只断言旧拒绝的检查而非保留镜像实现。
- 真实 Desktop + 真实订阅验收待用户授权部署后进行，在此之前不标通过。

## 回退

无 schema 变化；回退到上一提交即恢复严格校验。已在新版本绑定的提示不影响旧版本读取。
