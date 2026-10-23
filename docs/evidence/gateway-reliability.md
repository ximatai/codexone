# 网关活跃度与关键故障对照

核对日期：2026-10-23（Asia/Shanghai）。使用 GitHub 仓库、最近提交、发布、Issue 评论/时间线和指定修订源码；不按 star 数判断维护状态。外部问题报告不等于本项目有相同缺陷，外部测试数字不计本项目验收。全局进度及后续入口见 [STATUS](../../STATUS.md)。

本项目实现、测试缺口和本机合成探针的进一步分析见[可靠性核查](../changes/gateway-reliability-audit/proposal.md)及其验证账；本文件保留外部参考的固定快照依据。

## 参考对象选择

| 项目 | 最近默认分支提交（本次读取） | 最近读取到的发布（北京时间） | 选择 |
|---|---|---|---|
| [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) | [d946c4f](https://github.com/router-for-me/CLIProxyAPI/commit/d946c4fba6fc9a5cfbca1f3d85184d62ad2fb683)，10-23，Codex 请求身份处理 | [v8.0.40](https://github.com/router-for-me/CLIProxyAPI/releases/tag/v8.0.40)，10-23 | 活跃；本轮重点研究 Codex 目录/工具、长连接授权和失败分类 |
| [LiteLLM](https://github.com/BerriAI/litellm) | [f2118fc](https://github.com/BerriAI/litellm/commit/f2118fc7670ba3fa736d9b8f4deef9077a45a720)，10-22，安全修复 | [v1.106.2](https://github.com/BerriAI/litellm/releases/tag/v1.106.2)，10-21 | 活跃；本轮重点研究多轮上下文、可信终态和用量责任 |
| [New API](https://github.com/QuantumNous/new-api) | [33c61a2](https://github.com/QuantumNous/new-api/commit/33c61a24234aa20cb10e8a644304322c476361de)，10-23，管理界面修复 | [v1.0.0-rc.46](https://github.com/QuantumNous/new-api/releases/tag/v1.0.0-rc.46)，10-22；保留其 RC 版本名称 | 活跃；治理方向另轮按需研究 |
| [Bifrost](https://github.com/maximhq/bifrost) | dev：[f1175d6](https://github.com/maximhq/bifrost/commit/f1175d61fbf52940acb67edec9a4479d7cda27fd)，10-23；前一提交为治理功能 | [transports/v2.3.2](https://github.com/maximhq/bifrost/releases/tag/transports/v2.3.2)，10-21；这是组件发布 | 活跃；容量与运行治理另轮按需研究 |

四个仓库均未归档，最近有实质开发和发布。New API 与 Bifrost 的最近 PR 列表含当日实际合并；LiteLLM 最近提交包含已合并 PR，且仍维护多个稳定发布分支；CLIProxyAPI 有连续修复与发布。此为维护活跃判断，不代证协议完整性或上线质量。选择前两个是因其分别贴近当前客户端兼容和执行可靠性问题，不代表另两个较差。

## CLIProxyAPI：客户端接入与连接生命周期

### G01：能力目录必须与实际执行路径一致

[Issue 6769](https://github.com/router-for-me/CLIProxyAPI/issues/6769)报告非 Codex 路由继承默认模板后宣称 Lite/code mode，客户端按该能力发送请求而被实际后端拒绝。作者提供单变量对照及工具往返结果；这些是作者证据，本轮未重跑。

已核对关闭关联提交 [8df4e42](https://github.com/router-for-me/CLIProxyAPI/commit/8df4e42ab9ba27f072044cf20bb1b223a61f76bf)：非 Codex/混合路由及合成基线重置相关能力，并增加目录回归测试。GitHub ancestry 比较确认该提交进入 `v8.0.40` 源码。其取舍是缩小不支持路由的能力承诺，并非使所有后端原生支持 Lite。

[PR 4307](https://github.com/router-for-me/CLIProxyAPI/pull/4307)和[PR 4435](https://github.com/router-for-me/CLIProxyAPI/pull/4435)是另一条路线：为 xAI 变换 Lite 工具声明。两者均仍 open、未合并；已读 4307 的实现与 HTTP/WS 测试 patch，不能因其作者报告通过便视为主线能力，更不能通用于本项目原生订阅路径。

**本项目对应：** `ResponseRequest` 目前不支持 `additional_tools`，工具允许集合只从顶层建立；`ModelCatalog` 的显式目录与客户端内置默认目录是不同入口。[既有本机因果实验](../changes/parallel-key-trial/verification.md#用户要求先定位不修复后的只读调查)已证明当前缺口，用户真实 input 类型仍未采集。依据 P09/P11/P13，后续必须一起验证默认目录、显式受信目录、实际工具声明和结果续接；不能只放过 input 类型而遗漏工具输出校验，也不能静默改客户端目录来宣称原生 Lite 通过。

### G02：连接建立时授权不能替代每轮授权

[Issue 6843](https://github.com/router-for-me/CLIProxyAPI/issues/6843)报告长连接只在握手认证，撤销 Key 后同一 socket 的下一轮仍能执行。已核对关联修复 [b9bb031](https://github.com/router-for-me/CLIProxyAPI/commit/b9bb031dcbb05fdf293d78066e11a1473ddcd0ec)，包含每轮认证及撤销/模型拒绝测试；该提交进入 `v8.0.40` 源码。指定快照的 WebSocket handler 同时含普通与双向路径的逐轮调用，不只是新增一个未使用 helper。

**本项目对应：** P03/P07 与现有 `ResponsesDataService.serveTurns` 后续每轮调用 `executor.authorized(digest)`，随后走持久准入；有明确设计/实现依据，不能把外部缺陷直接归到本项目。后续在默认客户端闭环中核对：首轮成功后撤销/轮换/改模型权限，再在原连接发新轮；拒绝应无新上游执行。已派发工作的责任独立，不由撤销抹除。本轮仅静态核对，没有新运行验收。

### G03：网络故障、账号健康与是否能重试必须分开

[Issue 6668](https://github.com/router-for-me/CLIProxyAPI/issues/6668)报告网关 503 被当成账号故障，轮转后整个账号池进入冷却，后续只剩“无账号”。维护者[回复](https://github.com/router-for-me/CLIProxyAPI/issues/6668#issuecomment-6204844431)说明可用已有请求级规则避免冷却，并据此关闭；这是配置处理结论，不是声称新增了默认修复。其建议的继续换账号动作不符合本项目对未知执行的默认约束，不直接采纳。

另看[Issue 5734](https://github.com/router-for-me/CLIProxyAPI/issues/5734)：大上下文慢上传期间保活超时。已读关闭提交 [b5ba02c](https://github.com/router-for-me/CLIProxyAPI/commit/b5ba02c2e3627e975538e217575abee9f73eccd8)的写入/控制帧及回归 patch，并确认进入 `v8.0.40`。关闭之后仍有[复现反馈](https://github.com/router-for-me/CLIProxyAPI/issues/5734#issuecomment-5645853227)，反馈使用自定义桥接；最新评论对底层锁的解释未独立验证。因此不把该具体网络问题写成全部解决，也不将其认定为本项目偶发 TLS EOF 的原因。

**本项目对应：** P05/P06/P08/P10。后续样本区分慢上传、长时间无进度、代理故障、上游明确身份/限流拒绝，记录是否派发、上游次数及每个 owner 收尾；部分发送失败保持 unknown，不以“没收到答案”允许重放。现有本地容量包络不代证实际代理慢链路。本轮不改变健康分类、重试或超时。

### 关闭记录的反例

前次筛选引用的[Issue 6222](https://github.com/router-for-me/CLIProxyAPI/issues/6222)虽为 closed/completed，[作者关闭说明](https://github.com/router-for-me/CLIProxyAPI/issues/6222#issuecomment-5916821506)是转入自己 fork 继续开发，并非主线修复证明。它只作为多轮工具状态风险线索，不作为已验证方案。

## LiteLLM：完整消费、续接与执行责任

### G04：第一轮成功不足以证明上下文一致

[Issue 47881](https://github.com/BerriAI/litellm/issues/47881)报告启用加密上下文亲和时，逐项事件与最终结果给同一 reasoning 项不同 ID；客户端保留两份，下一轮回传后变成重复项并失败。已读取报告、复现评论及当前快照 `f2118fc` 的 `responses/utils.py` 和 `responses/streaming_iterator.py`：最终结果改 ID，而逐项事件只包裹内容，静态上与报告链路一致。本轮未运行 LiteLLM。

修复 [PR 47991](https://github.com/BerriAI/litellm/pull/47991)仍为 **open/draft**，head `3bc457e6f8a3c30bebf30bfdfb8e3d970803c086`。已读 patch 及测试；其方向是统一 ID、兼容旧编码并过滤恢复后的重复项。不能将草稿或作者的测试数字算作已发布修复，也不直接采纳其自动删重复历史的行为。

**本项目对应：** P06/P11/P13。未采用同样的 ID 包裹方式，不能认定存在相同问题；仍应在真实客户端消费后验证第二/第三轮：逐项与最终视图、引用归属、压缩上下文、同一 socket/新 socket 的结果一致。检查客户端实际保留和回传的内容，比单独检查响应结构更能暴露这类问题。

### G05：流结束与业务成功分开，原生与桥接分别验收

[Issue 40260](https://github.com/BerriAI/litellm/issues/40260)仍 open，报告干净 EOF 在部分桥接路径被补成成功；[PR 40266](https://github.com/BerriAI/litellm/pull/40266)也仍 open，未合并。

必须同时记录已经完成的部分：[PR 43133](https://github.com/BerriAI/litellm/pull/43133)已于 09-26 北京时间合并，merge `1fd04abb9278ef3b33379009874f75fe32e27315`，进入 `v1.106.2` 源码；已读其原生 Responses 提前结束检查与失败测试，当前快照仍有缺终态时报错的代码。不能将桥接剩余问题泛化为“LiteLLM 所有 Responses 仍会伪造成功”。它的未输出 fallback 策略也不代表本项目可在已派发后重放。

**本项目对应：** 当前 `HTTPResponseExecution` 在流无可信终态时抛 `execution_indeterminate`，协议脚本已有 EOF 场景；这只是静态复核/已有记录，本轮未重跑。后续以 P06/P10/P11 检查原生 HTTP、HTTP→WS、原生 WS 在正常终态、干净 EOF、半截帧、仅保活、取消五种情况下，客户端显示、用量和 unknown 各自一致。当前部署夹具缺 `total_tokens` 的独立问题仍按原记录保留，不能用 HTTP 200 替代客户端完成。

### G06：用户看到结果与用量可靠记账必须独立保证

[Issue 34351](https://github.com/BerriAI/litellm/issues/34351)仍 open，报告桥接遗漏 incomplete/failed 中的上游 usage；最新评论仅为 stale bot，不能算维护者确认或修复。另一项 [PR 47386](https://github.com/BerriAI/litellm/pull/47386)仍 open，head `a1c84c9212cc676e75cef26427f243f7dd8b9aba`，处理慢日志 hook 使成功请求的记账被取消；已读提案与相关记账文件 patch 范围，未复跑其测试，不吸纳其捆绑依赖更新。

**本项目对应：** `HTTPResponseExecution` 对 completed/failed/incomplete 均先观察可信 usage，再校验/绑定/输出；`ExecutionObservation` 区分结果与证据；没有同样的外部日志 hook 记账链。现有图片脚本亦含失败/不完整终态用例，不能据外部报告宣布本项目有漏账。后续针对 P05/P13 与持久结算约束，核对完整/部分/无用量、输出失败、取消、日志/存储异常：已知证据不丢、不重复，缺失不填零，不将账本写失败视为可忽略的日志失败。

### 排除过时安全结论

[Issue 35536](https://github.com/BerriAI/litellm/issues/35536)已关闭 not_planned，最后说明引用 [PR 39548](https://github.com/BerriAI/litellm/pull/39548)及启动配置检查，并指出剩余情况未验证。39548 于 09-12 北京时间合并，merge `1dc0e363b0c62ced71671ed91454a476ef544f90`，进入 `v1.106.2` 源码。因此不再把最初正文中“任意原始 ID 均跳过归属”的历史描述当成当前事实。可借鉴的是对未知 ID 的显式拒绝策略；本项目继续按自己的主体/账号归属契约验收。

## 后续验证的取舍依据

| 顺序 | 要回答的问题 | 证据与限制 |
|---|---|---|
| 1 | 默认客户端能否完整完成文本和工具往返，并继续第二/第三轮？ | 优先覆盖 G01/G04/G05；采用实际候选夹具和明确客户端版本，默认/显式目录分别报告。当前已知兼容缺口未解决，仍阻塞该出口 |
| 2 | 原连接中撤销、失败、取消和慢链路是否保持权限与执行责任？ | G02/G03/G05；验证上游次数、逐轮拒绝、owner 释放和 unknown。具体外部故障不作为本项目已复现缺陷 |
| 3 | 所有终态与部分失败是否正确保留用量？ | G06；区分结果、已知证据与持久屏障，不用成功响应或日志存在替代账本核对 |

本轮证据限于公开资料/指定 patch 与本项目静态对照；未执行外部项目测试或真实提供者调用。祖先关系只证明指定修复进入发布标签的源码，不证明发布二进制、配置或运行行为。后续实施须另行更新提案/任务与规范；本文件不授权修复、部署、扩展范围或调用真实订阅。
