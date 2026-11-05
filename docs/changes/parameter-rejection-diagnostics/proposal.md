# 订阅参数拒绝诊断

修正准入前拒绝的统计分类，并在不记录内容的前提下定位受限参数。

## 问题与方案

订阅请求在准入前按 P26 拒绝不支持的参数时返回 `400 unsupported_backend_parameter`，但拒绝诊断复用执行失败映射，将其记录为 `indeterminate`。日志也不能区分命中的受限字段。

仅在准入前记录拒绝的位置，将该固定错误码且状态为 400 的错误归为 `invalid_request`。执行内失败分类、未知责任、准入事务和上游派发不变。既有协议诊断的固定 `reason` 枚举增加八个参数类别：max_output_tokens、temperature、top_p、truncation、prompt_cache_retention、metadata、store、previous_response_id。多字段请求仍按既有校验顺序报告首个拒绝，不新增任意字段名或值采集。

依据 [P26/P27](../../reference/specs/protocol.md)、[U10](../../reference/specs/usage.md)。保持原 400 状态、错误码和公开 envelope，不放行参数、不静默删除约束。日志沿用既有 16 条/60 秒限额；不记录请求正文、参数值或提供者错误文本。

## 验收

- 真实本地 HTTP（HTTP/WS 上游配置）与原生 WS：受限字段返回原 400，零 attempt、零上游调用/握手，拒绝诊断为 invalid_request。
- store 与 previous_response_id 同时存在时先报告 store；HTTP 的 previous_response_id 拒绝不改变原生 WS 的续接契约。
- 固定 reason 可辨识字段，公开 envelope 和日志不含合成私有标记；null 参数及其他合法请求保持原行为。
- 执行内同码错误与未识别错误仍按原映射分类；既有已准入请求不得增加拒绝诊断。

## 数据与回退

无 schema、配置、用量、恢复或迁移变化。只改变新准入前诊断的 failure 分类；不重写历史 indeterminate，无法从旧行还原具体参数。代码回退后新诊断恢复旧分类，既有 invalid_request 为已支持枚举，无数据库回退要求。

## 相关文档

[任务](tasks.md)
