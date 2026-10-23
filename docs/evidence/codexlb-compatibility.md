# CodexLB 接入行为对照

核实日期：2026-10-23。用户指定本地项目；主Agent只读双方源码及部分相关测试，未运行旧服务、访问真实资料或调用提供者。本记录不证明线上版本、测试通过或当前真实协议。全局进度见[STATUS](../../STATUS.md)，执行证据见[核对记录](../changes/codexlb-compatibility-audit/verification.md)。

## 版本与方法

- CodexLB工作树：`6d788664ff982c87887924694c103c9bc49331fd`，已跟踪内容无修改；存在未跟踪工作，未读取/修改。未fetch、checkout、pull或启动旧项目。
- 本地另一历史修复快照：`6689178b9a5a7d0f945f8d95ea5530c5808ce6a3`。只用git对象读取指定源码，不因分支名称/提交说明推断其仍在线。
- CodexOne：`16e9a7a`；冻结候选源码仍为 `bd38964`。本次不改生产代码。
- 两份旧源码的图片转换、OAuth、usage客户端及模型、模型获取和默认设置逐字节相同；桥接/持久库/API不同。下述完成事件重放分支在两份源码均核对存在，不将整个实现视为相同。

## 对照结论

| 项目 | 旧源码的行为证据 | CodexOne现状与取舍 |
|---|---|---|
| 接入与模型目录 | `app/modules/proxy/api.py` 的 `models/v1_models` 根据 `client_version` 提供Codex目录；`app/core/clients/model_fetcher.py::fetch_models_for_plan` 读取上游模型元数据与 `base_instructions` | 已有两个接入前缀与Codex目录，但 profile/基础指导来自显式私有配置，目录部分工具/指导能力固定关闭。目录形状通过不等于默认Desktop能力等效；需确认受信profile来源、版本与能力清单，不能填空指导或假装支持未实现工具 |
| 已有输出重放 | 桥接 `request_submit.py` 对既有 `completed/incomplete` 且 `event_spool_complete` 的operation读取事件，送入当前请求的事件队列后return，不必新增GET接口 | 当前无事件缓存或重复POST识别。不能再将“客户端没有GET读取轨迹”单独作为排除此路线的理由；但旧源码不能证明目标Desktop能安全消费全段重放 |
| 操作关联 | `durable_bridge_repository.py::durable_bridge_operation_fingerprint` 包含API Key scope和请求文本；桥接另结合session、previous_response_id、hard turn-state等条件，处理连续相同请求的anchor推进 | 相同正文不是幂等授权。必须实测同一次重试的稳定关联与主动相同新turn的区分、当前权限/账号/恢复代际、已消费工具输出；不照搬指纹规则 |
| 未知执行与重新派发 | 旧桥接另有 `fail_closed/client_full_history_once/server_anchored_replay_once/server_indefinite_recovery`；默认fail_closed，其他模式会进入额外恢复派发分支 | 保留派发后不换账号、不自动重生成；原unknown与预留不清除。持久互斥可避免同时派发，不能证明远端仅执行一次。不能把这些模式统称为已有输出读取，也不能一概说旧服务总会重试 |
| 登录/刷新 | `app/core/clients/oauth.py` 为code exchange使用form/PKCE；`app/core/auth/refresh.py` 为refresh使用JSON；登录增加简化流程/originator参数，刷新带scope；还实现device flow | 主要grant编码一致；当前code-flow额外要求nonce、issuer/audience/subject/account一致，无device-flow，不复制登录缓存。附加参数/返回声明/令牌轮换/失败分类需真实认证独立验收，不能从合成成功推出生产兼容，也不凭旧代码降低验证 |
| 被动额度 | `app/core/clients/usage.py` GET wham/usage，可对瞬态失败重试；`app/core/usage/models.py` 包括窗口、reset_after_seconds、credits/reset credits、附加额度与plan/workspace/seat等 | 固定usage GET与主/次窗口/附加窗口方向一致；当前不重试观察、不兑换reset credits，不把缺失字段补零或全模型禁用。未消费的credits/相对重置/套餐字段不等于已支持；旧源码不能证明各套餐实际返回哪些字段 |
| 图片适配 | `images_service.py` 将Images翻译为宿主Responses的image_generation工具，强制tool_choice，编辑action=edit，n=1；mask追加为input_image并附提示；内部请求始终stream=True/store=False | 宿主映射、工具选择、主动编辑方向一致；当前mask放入工具input_image_mask，内部stream跟随请求。两种mask表达及JSON/流式上游组合均缺真实订阅等价性证据，不直接照搬提示或声称mask编辑已通过；不扩展远程图片/文件服务 |
| 单次期限/负载 | `app/core/config/settings.py` 默认普通代理预算600秒、HTTP流/桥接7200秒、compact180秒、流空闲7200秒；单事件16MiB、上游create15MiB | 当前单次最大120秒、独立compact同属有界期限，图片事件8MiB/外部正文8MiB。是明确兼容差异；125秒多turn不覆盖单次超过120秒，也不证明全部图片尺寸等效。旧默认不是实际部署值，不直接放大资源上限 |

## 需要修正的判断

此前CLI EOF实验只证明：在**当前无缓存网关**上，该CLI会另发create并产生新执行。它没有证明所有网关都无法利用重复POST提供已提交事件，更没有排除CodexLB式透明重放。GET retrieve/消费序号是候选路径之一，不能成为唯一前提。

另一方面，“旧服务存在完整事件spool”也没有解除C10：全段事件重放不等于从已消费位置续读；工具可能已被执行，`incomplete`不能当成功完成；缓存缺失/过期、权限变更、归属冲突和崩溃窗口仍需失败闭环。重建上下文后调用上游是新执行，不满足C05的只读恢复。

## 推荐验证顺序

1. **先补一个新的合成关联实验**：观察明确CLI版本在首次输出、终态丢失及显式相同新turn时的请求/会话关联；分别验证完整文本事件重放、已有前缀重放、权限撤销和跨主体拒绝。必须记录上游调用次数与原执行责任；这不是重复现有EOF探针，也不是先实现缓存。工具只用无副作用夹具，工具重放与图片仍单列未验。随后按用户约定讨论Desktop操作方式，确认真实UI能否消费同一路线。
2. **期限和目录作为Desktop正常体验的前置设计项**：用合成上游证明单次持续进度超过120秒与静默超时的区别，提出总期限/空闲期限/取消/资源预算；明确可信模型profile的获取/更新方案及默认工具范围。行为变更先独立提案、定向验证，再更新候选，不悄悄放宽当前限制。
3. **Desktop第一轮仍使用合成上游**：按[准备矩阵](../development/desktop-preflight.md)核对文本/工具/预热/压缩/图片、主动新turn与断线；记录配置恢复步骤。Desktop实际操作方式未讨论前不启动。
4. **真实订阅最后单独授权**：认证/刷新、目录、额度以及JSON/流式图片/参考图/mask，按明确提供者与客户端版本验证。不借只读参考授权触发登录、刷新、GET额度或生成。

此顺序不选择私有恢复协议，不允许自动重执行，不将旧服务源码作为安全结论或当前产品验收。M5、真实Desktop/订阅和完整O14继续保留。
