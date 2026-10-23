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
