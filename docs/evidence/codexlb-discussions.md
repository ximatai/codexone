# CodexLB Issue / PR 讨论依据

核实日期：2026-10-23。通过GitHub只读连接读取正文、状态及讨论；主要补充[源码对照](codexlb-compatibility.md)的动机和代价。作者自述/维护者分析、合并状态和本项目验证分别看待，不复制原始评论/日志，不推断当前线上行为。以下PR状态是本次读取的快照。

| 来源与状态 | 核实到的争议或实践 | 对本项目的含义 |
|---|---|---|
| [Issue 1707](https://github.com/Soju06/codex-lb/issues/1707) 仍open；[维护者说明](https://github.com/Soju06/codex-lb/issues/1707#issuecomment-5586440512)及[后续状态](https://github.com/Soju06/codex-lb/issues/1707#issuecomment-5866465200) | 旧线程所属账号不可用时，新线程仍可工作。软sticky设置不能解除硬归属；可迁移范围受明文完整度、加密推理、压缩和owner证据约束，维护者仍列出多项残余缺口 | 采用明确的会话归属失败与处理路径，不用“池里还有账号”推导可以切换；不把持久ID存在当上游对象仍有效 |
| [PR 1900](https://github.com/Soju06/codex-lb/pull/1900) closed/unmerged；[关闭原因](https://github.com/Soju06/codex-lb/pull/1900#issuecomment-5662636537) | 维护者认可完整transcript需求，但指出已发布迁移ID被改名、私有分支迁移修补膨胀、恢复功能夹带公共生命周期严格化。大型PR的测试规模没有解除这些问题 | 不整包移植。已发布schema身份和恢复语义稳定；恢复与公共协议变化分开取证，不能为匹配夹具静默收窄既有合法上游形状 |
| [PR 2430](https://github.com/Soju06/codex-lb/pull/2430) open/unmerged；[维护者阻塞说明](https://github.com/Soju06/codex-lb/pull/2430#issuecomment-5866463905)；[Issue 1898状态](https://github.com/Soju06/codex-lb/issues/1898#issuecomment-5866475402) | 拆分后的schema和纯函数仍没有接运行写读路径，维护者质疑提前增加列/索引的成本及误关业务Issue | 技术切片可内部提交，但按可操作闭环验收；不为未来缓存预建schema/索引，不把迁移/纯函数通过当恢复完成 |
| [PR 1974](https://github.com/Soju06/codex-lb/pull/1974) merged；[keepalive讨论](https://github.com/Soju06/codex-lb/pull/1974#discussion_r3889302760) | 首响应前无事件、实际流空闲、本地重置和连接活性曾混成同一错误；维护者说明代理发出的keepalive不能证明模型工作有进度 | 总期限、首响应、执行进度空闲和连接保活分别建模；本地心跳不能延长无进度执行，不将本地计时器误归咎于上游账号 |
| [Issue 2041](https://github.com/Soju06/codex-lb/issues/2041) closed/completed | 报告通过真实RST/FIN对照定位长keepalive下的协议对象/定时器残留；7200秒连接空闲配置放大资源保留。属于Python/uvicorn实现案例 | 借鉴生命周期/异常断开验收，不推断Swift存在同一bug；长推理预算与HTTP空闲连接寿命分开，不直接复制长keepalive值 |
| [PR 2221](https://github.com/Soju06/codex-lb/pull/2221) merged | 把期限迁入管理台时，需区分默认/环境/显式设置来源；讨论正文保留动态缩短预算影响旧claim回收、潜在重复执行的后续问题 | 保留有效配置来源，执行采用准入时快照。单管理员小平台先用少量私有配置，不急于增加热更新和每类计时器的界面开关 |
| [PR 2543](https://github.com/Soju06/codex-lb/pull/2543) open/unmerged | 作者报告特定Codex版本需同时开启API-key发现和指定目录URL，仅服务端返回模型不保证出现在选择器；没有维护者合并结论 | 安装配置与目录API要一起验收；能力profile版本化，不以模型名、catalog解析成功或客户端fallback当正常能力证明 |
| [PR 903](https://github.com/Soju06/codex-lb/pull/903) merged；[PR 2508](https://github.com/Soju06/codex-lb/pull/2508) open/draft；[维护者要求](https://github.com/Soju06/codex-lb/pull/2508#issuecomment-5866473965) | 903以真实无效图片在桥接中悬挂为由改走HTTP；后续复用图片桥接方案仍缺真实无效图WS帧证据。维护者区分本轮图片与历史图片，并指出合成error帧不能证明真实提供者会这样报错 | 不宣布HTTP或WS普遍更好；按当前输入/历史/图片工具组合列验证矩阵，错误及时可见优先于缓存命中；未确认create结果不重发图片 |
| [PR 2537](https://github.com/Soju06/codex-lb/pull/2537) open/unmerged，head `fe60885852e4c50a2c2890c44cc1b14879310632` | 作者报告图片宿主拒绝forced tool。实际patch有独立宿主候选，也有Responses入口128→256MiB的额外放宽；宿主resolver在无合格候选时仍返回默认名称 | 吸纳公开图片模型/宿主能力分离，保留本项目显式映射和无能力拒绝；不照搬模型名候选或大请求阈值，不把“存在候选”当已验证能力 |
| [PR 1718](https://github.com/Soju06/codex-lb/pull/1718) merged；[Issue 2081](https://github.com/Soju06/codex-lb/issues/2081) open | 讨论区分流空闲/无close帧的传输损失、真实账号限流，以及已选owner的上游错误被改写成owner不可用；重放许可与健康归因不是同一个判断 | 采用有证据的失败分类，避免网络故障污染整个池；可读诊断与脱敏原因为先，不为保留错误细节泄露上游正文或授予重试权限 |
| [PR 2303](https://github.com/Soju06/codex-lb/pull/2303) open/unmerged；[维护者分析](https://github.com/Soju06/codex-lb/pull/2303#issuecomment-5662649252) | 已就绪积压仍按flush间隔睡眠，会挤占终态持久化预算；改动强调每轮有界公平且推进、失败不能忙循环 | 后续缓存批写须以终态可恢复和核心writer不饥饿验收，不以压缩率、批次数或孤立吞吐充当产品收益 |

读取限制：PR1900合并讨论工具首次返回transport错误，改用只读Issue评论入口取得维护者关闭说明；不将失败调用算已读。没有穷举全部Issue/PR、复跑外部测试或审计这些PR全部代码；2537额外核对了host_models与ingress_limits实际patch。未访问真实提供者，未触发远程评论、review、推送或部署。

本项目选定方向、拒绝项与成本见[兼容取舍](../decisions/compatibility-policy.md)。所有外部测试数字均未迁入本项目验证结果。

## 2026-10-23 通信契约扩展复核

本轮通过只读连接核对以下Issue、PR正文/patch及所列维护者讨论。六个新增PR在读取时均为open/unmerged；归档目录、作者测试和bot评论不代表已合并或本平台通过。原始patch/评论未复制入库。

| 依据 | 可吸收内容及边界 |
|---|---|
| [Issue1184](https://github.com/Soju06/codex-lb/issues/1184)，closed/completed | 缺省tools被DTO默认值补成[]可触发保留工具schema拒绝；工具排序只能用于缓存指纹，不能改变线上数组/声明。当前可选reasoning回归已检查tools存在性；不能据此声明已支持Responses-Lite/additional_tools。 |
| [PR2569](https://github.com/Soju06/codex-lb/pull/2569)，head `778e10f4ab7111c7ab5539b448df2763fabc1987` | 作者报告developer消息提升到instructions后，在previous_response_id续接时丢失。当前平台保留developer原位置，合成HTTP实测收到的input与工具数组/嵌套required顺序相同；不照搬system提升或删除历史，真实提供者system接受情况仍待验。 |
| [PR2634](https://github.com/Soju06/codex-lb/pull/2634)，head `f7bf33633223af8ad3f8c3a3fce50f20febcccbb` | 长连接不能永久缓存账号可用性，应在每次新turn准入复核；已派发与未派发分开处理。当前平台每turn经账号池及SQLite账号/Key版本屏障，并非仅握手认证；派发屏障后的微小竞态不能承诺绝对即时撤销，维持既有责任语义。 |
| [PR2472](https://github.com/Soju06/codex-lb/pull/2472)及[维护者分析](https://github.com/Soju06/codex-lb/pull/2472#issuecomment-5866469378)，head `bfffc82d40f1b60b6c165e53278226004736de1a` | 吸收真实组合路径的生成器/租约收尾验证；维护者复现finally未执行，并要求独立修复。拒绝把传输损失伪装成rate_limit_exceeded来诱导重试：维护者指出未知response.failed也可能被Codex重试，伪装会污染下游额度分类。终态、清理和重试许可分别验证。 |
| [PR1903](https://github.com/Soju06/codex-lb/pull/1903)及[维护者方案取舍](https://github.com/Soju06/codex-lb/pull/1903#issuecomment-5662636957)，当前head `b28036815f619d0da436414db367ae4bc64f3941` | 历史关闭讨论提出共享reader不得因单消费者阻塞：每请求保留字节上限、全局预算、原前缀后失败/EOS及释放责任。当前平台已有有界inbox与5秒push期限，但共享reader仍可能等待一个lane、超时后影响整socket；这是自身源码发现的隔离风险，尚无本轮独立对抗实测，不写成已解决。 |
| [PR2581](https://github.com/Soju06/codex-lb/pull/2581)，head `d83dac5b4fc1159a19fd539bc635e3425eecee9a` | 原完整历史与旧socket锚点不能混用；加密agent消息不因恢复而跨账号。当前不自动注入previous_response_id，且agent_message不在已支持输入集合；保留明确不支持，不自动删消息或赋予重放资格。 |
| [PR2589](https://github.com/Soju06/codex-lb/pull/2589)，head `c22607d0f11e74aa871ae518e08e8f6404237bc0` | HTTP/WS客户端指纹应有一致、有限的契约，不能由随意header扩大路由能力。该PR还夹带依赖升级，不整包吸收。当前订阅上游只组装验证后的账号头，未实现其客户端指纹/版本/beta选择策略；合成fixture不证明真实握手兼容。 |

### 自身代码与合成对照结果

固定旧源码仍为 `6d788664ff982c87887924694c103c9bc49331fd`。`ResponsesTextControls`的verbosity/format及`ResponsesRequest`的tool_choice/parallel_tool_calls可空，转发exclude_none；当前平台仅修复已知reasoning成员。本轮真实本机HTTP合成探针确认：四项显式null分别得到unsupported_text、unsupported_text、unsupported_tools、invalid_request（均400）。这是待扩展的参数契约差异，不是读取用户正文后的结论；不能用全局删null处理tools等非可空字段或未知成员。

另核对旧源码 `core/clients/proxy_websocket.py::_build_upstream_websocket_headers` 的Responses beta、安装ID与有限头处理，以及当前 `WebSocketUpstream`/`SubscriptionDataAccess`。当前没有等价的beta/客户端版本策略；opaque turn-state也不能直接透传，它需要Key/账号/恢复代际归属验证。文件上传、history/notes、异步工具和steering属于独立有状态接口，不能当作多放行一个JSON字段解决，也不能通过复制模型目录提前宣称支持。

当前 `WebSocketTurns` 首事件要求response.created，独立error首帧会走invalid_upstream_turn；这项源码差异应与流中失败终态一起增加真实socket负向样本，区分安全错误映射、unknown与账号健康，不直接透传原始上游错误正文。当前没有本轮提供者实测，不据此宣布真实订阅缺陷已确认。

建议下一闭环集中处理“已知可选参数与失败可见性”：字段逐项缺省/null/显式值/错误类型矩阵，HTTP/SSE/原生与桥接WS同样的上游文档，首帧/流中拒绝、终态唯一与owner清理；再单列多lane慢读隔离和订阅握手头契约。保持主Agent实现、定向测试、一次集中review/出口验证；不按每个字段反复全量构建。真实订阅继续关闭，M5和Desktop完整验收不因本轮对照完成。
