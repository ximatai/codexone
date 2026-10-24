# 普通输出视图与请求参数闭环

依据P08—P11/P13—P15、E03/E08、U01/U02及[协议矩阵](../../evidence/text-protocol-matrix.md)，按用户要求先补普通输出一致性，再补请求参数；只使用无凭证合成上游，不部署或新增真实订阅调用，不改schema/重放/账号健康策略。

## 普通输出

每次执行持有有界关联状态，覆盖message、function/custom call及reasoning；上限沿现有最终窗口16项、每项128个内容/摘要part。只保留ID/索引/类型及SHA-256/长度，不保留另一份正文或密文，也不持久化新内容。状态随该执行释放；图片与流式压缩维持各自现有校验。

- 明确提供的output_index、item ID/type、call_id/name/namespace/role不可相互冲突；同一窗口不能重复ID或调用ID。
- added允许in_progress与内容前缀逐步完善；delta、字段done、item.done及completed中已提供的同一语义字段须一致。空annotations/logprobs、可空/缺省展示元数据不作为整对象字节比较依据。
- 文本/refusal、function arguments/custom input及reasoning内容/摘要分别关联。reasoning可在最终快照省略可选内容，但已经提供的相同完整字段不能改值；不从元数据建立绑定。
- 保持稀疏HTTP流：索引可由明确item ID及最终位置补全；无ID/索引的文本仅在可唯一关联单项时接受，不能在多项之间猜归属。仅终态窗口也要验证重复身份。
- 先确认执行response归属，再观察可信终态用量；跨视图校验在新绑定和下游提交前执行。冲突失败不伪造成功、不删除历史；已可信用量保留，缺证据仍unknown。WS reader已有提前计量屏障保留。

## 请求参数

[官方Responses字段](https://developers.openai.com/api/reference/resources/responses/methods/create)及[固定Codex请求结构](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/common.rs)用于核对形状；通用入口接受不代表每个上游支持。

- 在准入前校验已有采样/输出上限的数值类型、范围及tier/truncation/cache retention枚举；错误不创建attempt、不调用上游，不记录任意值。
- 由可信配置选择普通Responses或Codex订阅请求契约；真实订阅及账号池固定后者，loopback可显式选择它供合成验证。下游不能改契约。
- 普通订阅HTTP统一使用stream=true/store=false；下游JSON由已验证完整终态输出，SSE仍逐事件输出。显式store=true拒绝，不默默降低存储语义；HTTP previous_response_id拒绝，native WS维持同连接关联。
- 输出上限、采样、截断及其他未纳入选定订阅支持范围的非null字段准入前明确拒绝，不静默删除硬约束。null仅表示未指定。保留支持字段、完整输入顺序与工具位置；字符串输入转换为等价user消息数组。
- 图片和独立compact不借本轮扩大能力或变更它们的消费语义；模型特定支持仍由提供者判断，不把有界合成检查写成真实模型支持。

## 验收

独立字面量样例覆盖HTTP JSON/SSE、HTTP→WS与native WS，正向稀疏/快照增长/多项/两轮及负向内容/工具身份/索引/重复/终态缺项；检查失败分类、精确调用数、绑定、可信usage/unknown、无正文日志。参数组检查支持字段实际到达上游、JSON与SSE适配、拒绝零派发/零attempt及配置不可被下游覆盖。主Agent定向修复、自查提交，出口集中review、相关回归与两平台验证；不凭脚本要求用户重试Desktop。
