# 项目状态

公开能力范围、已知限制和后续方向的简明入口。

## 版本与能力

当前稳定版本为 **[v0.26.33](https://github.com/ximatai/codexone/releases/tag/v0.26.33)**（2026-11-12），核心数据库 schema v15。镜像发布在 GHCR `ghcr.io/ximatai/codexone`（Linux amd64），附来源证明；也可以从源码构建。

v0.26.33 修复窄屏用量页日期浮层遮挡，更新 Mantine 和 Swift 网络与日志依赖，并补齐 BoringSSL 许可正文。见[发布说明](CHANGELOG.md)。

v0.26.32 统一管理台截图隐私遮罩的样式，补充 Codex 协议、动画 GIF 和实时输出速率零值的回归，并更新部分前端及测试依赖。见[发布说明](CHANGELOG.md)。

v0.26.30 补充原生 WebSocket 的预热后重连、同连接迟到中断和双账号 429 归属回归，沿用 schema v15。见[发布说明](CHANGELOG.md)。

v0.26.29 在订阅账号详情展示近 24 小时和近 7 天的额外积分余额历史，升级至 schema v15。见[发布说明](CHANGELOG.md)。

v0.26.28 缩短主分支日常验证，收敛重复浏览器用例，沿用 schema v14。见[发布说明](CHANGELOG.md)。

v0.26.27 统一镜像清单的 schema 版本来源，按风险选择开发验证和旧镜像验收，沿用 schema v14。见[发布说明](CHANGELOG.md)。

v0.26.26 调整首页 Token 卡的量级单位和账号详情的积分余额显示，沿用 schema v14。见[发布说明](CHANGELOG.md)。

v0.26.25 将已知响应元数据及 WebSocket 耗时遥测从未知协议观测中排除，沿用 schema v14。见[发布说明](CHANGELOG.md)。

v0.26.24 调整首页额度趋势图例顺序，缩短 PR 验证等待，沿用 schema v14。见[发布说明](CHANGELOG.md)。

v0.26.23 新增管理台截图隐私模式和账号额外积分只读余额，优化额度趋势、侧栏与选路诊断，沿用 schema v14。见[发布说明](CHANGELOG.md)。

v0.26.22 在首页提供今日准入拒绝明细，支持按固定原因分组筛选。从正常 v13 启动时自动迁移到 v14。见[发布说明](CHANGELOG.md)。

v0.26.21 在首页订阅额度卡展示额度历史与耗尽预测，沿用 schema v13。见[发布说明](CHANGELOG.md)。

v0.26.20 更新首页请求输出速率曲线，增加今日 Key 生图统计和管理抽屉入口，为在途请求和桌面侧栏加入过渡。沿用 schema v13。见[发布说明](CHANGELOG.md)。

v0.26.19 修正首页运行资源的曲线标题对齐，沿用 schema v13。见[发布说明](CHANGELOG.md)。

v0.26.18 把首页请求输出速率改为近 7 天小时趋势，并统一运行资源折线读数布局。沿用 schema v13。见[发布说明](CHANGELOG.md)。

v0.26.17 在启动时自动迁移符合条件的 v12 账本，先生成迁移前备份，再事务升级到 v13。升级与回退边界见[维护指南](docs/guide/backup-upgrade.md)。

v0.26.16 让首页近 7 个业务日的请求输出速率跨重启恢复。升级需停服备份并显式迁移。见[发布说明](CHANGELOG.md)。

v0.26.15 补充 Responses 首事件前失败诊断，区分鉴权拒绝、连接、握手与首事件前断开，关联准入凭证版本。见[发布说明](CHANGELOG.md)。

v0.26.14 在请求明细区分上游未完成，首页增加数据盘可用空间趋势与最新读数，并精简 Linux amd64 运行镜像。沿用 schema v12 和现有部署维护命令。见[发布说明](CHANGELOG.md)。

v0.26.13 将首页输出速率改为按已结算请求的端到端耗时计算，近期与日趋势展示中位数。协议观测移至首页运行资源下方，有记录时显示。见[发布说明](CHANGELOG.md)。

v0.26.12 更新首页实时概览，增加生图张数、结算输出吞吐、订阅额度时间参考线和 Linux 一分钟负载。管理推送中断时回退至 HTTP，数据库沿用 schema v12。见[管理面规范](docs/reference/specs/control-plane.md)与[发布说明](CHANGELOG.md)。

v0.26.11 改善 Responses 模型标识与重试提示、未知字段转发和原生 Images 的 JSON 与流式错误兼容。已验证真实 Codex CLI 的 PNG 生成和参考图编辑，以及 Desktop 手动压缩后的会话续接和工具调用。本次 Desktop 样本的压缩路由仍未确认。见[兼容范围](docs/reference/compatibility.md)与[验收记录](docs/changes/transparent-client-protocol/tasks.md)。

项目是个人自托管网关：管理自己的 ChatGPT/Codex 订阅账号，为自己的多台设备和工具分别发放 Key。已实现账号授权/刷新与额度观察、Key 权限/轮换/归档/全部模型范围、本地限额和用量诊断、Responses HTTP/SSE/WS 与桥接、预热/压缩、原生图片生成/参考图编辑、同源管理面板、快照备份和维护迁移；v0.26.2 起提供设备码授权、可选局域网 HTTP 模式与网关自动重启；v0.26.4 起提供订阅重置卡查看/确认使用/到期前自动使用，以及空闲 5 小时/每周配额窗口预热（均按账号默认关闭）。

v0.26.5 起重置卡自动使用支持分钟级提前量和有界分钟重试，未知结果沿原请求 ID 核对；v0.26.6 起上游过载统一递增节流并支持准入前有界等待，429 与认证屏障不变；schema 仍为 v11。

托管 Key 策略仅接受每日 Token 与最大并发，旧请求次数不换算；升级前须保存完整 bundle，写入新策略后不能原库回退至 v0.26.5 及更早版本，见[Key 回退前提](docs/guide/key-governance.md#兼容回退前提)。

从 v0.26.3 及更早版本升级须按[维护指南](docs/guide/backup-upgrade.md)停服备份迁移到 schema v11，v10 及更旧程序拒绝 v11。

上游订阅 HTTP 大请求新增有界 zstd 上传与 `off` 回退；响应事件前 415 仅同账号明文重发一次。版本号不变，Linux/真实上游及内存发布门禁见[验证记录](docs/changes/upstream-zstd/verification.md)。

v0.26.10使用 64 MiB 共享正文预算并保留 8 MiB 小请求余量，短时等待容量。GIF/SVG 沿图片权限与模型范围转发，原生显式 GIF/SVG 按实际格式头验收。真实格式和 Responses 图片工具可用性依赖提供者。SVG 作者输入与输出计入 Key 每日 Token 上限，费用覆盖独立展示。升级至 schema v12 需要显式迁移与升级前备份。详见[协议](docs/reference/specs/protocol.md)、[兼容说明](docs/reference/compatibility.md)与[维护指南](docs/guide/backup-upgrade.md)。

## 管理界面与 Token 治理

首页大数按万/亿/万亿展示并保留精确值提示，容量以进度条区分参考阈值与阻断上限；今日未归档托管 Key 的成功、失败、取消、执行中与结果未明汇总（仅今日有准入，停用状态明确标注）替换最近请求明细。大屏拓宽侧栏并合并运行状态，订阅额度窗口纵向展示已用比例、时间参考线和重置时间。仅在有事项时显示运行提醒。只读摘要新增成功、取消与在途计数，无 schema 变化。本机定向验证与平台边界见[验证记录](docs/changes/overview-summary/verification.md)。 首页账号入口现就地打开复用的详情抽屉，保留首页导航、滚动与历史恢复；详情按概览/自动化/设置分组，固定头部、按需读取配置并保留页签间草稿；账号设置只提供启用/禁用；手动使用重置卡仅保留各卡自己的使用按钮与确认；精简重复说明，由分组与数字列传达信息，保留异常和操作后果提示。首页大屏分为用量与实时请求主栏、订阅额度与资源侧栏。进行中请求以卡片显示，结束后移除。今日活跃 Key 按已观测 Token 降序，可按失败率进入当日诊断。Linux CPU 和两种内存的小时趋势使用进程内采样。见[首页验收](docs/changes/overview-operations/tasks.md)。

访问密钥默认筛选可用，“全部”包含已归档；列表精简为身份、权限、状态、用量与最近使用，详情抽屉统一查看与管理操作；Key配置仅每日Token上限与最大并发，单位切换保留数量；根据已观测Token阻止后续准入，不保证绝对封顶，旧请求次数不自动换算；用量摘要以Token为主，费用收至统计明细。凭证安全规则不变。

每日Token限制的验证与平台边界见[验证记录](docs/changes/daily-token-limit/verification.md)。

v0.26.7 起统一跨传输会话软亲和与双向协议元数据；真实续接 token 独立约束来源，未知状态明确拒绝；辅助 5xx 按端点隔离，429/401 保留账号级保护。契约与验收见[会话路由任务](docs/changes/session-routing-metadata/tasks.md)。

v0.26.8 起网关保留 JSON 对象键顺序，相同请求发往上游的正文稳定；真实提示缓存验收见[任务](docs/changes/preserve-json-key-order/tasks.md)。

上游 WS 大请求现按最终编码消息预检：独立 HTTP 调用超过 12 MiB 预先走 HTTP，原生 WS 超过同一 12 MiB 阈值沿既有路径拒绝，并识别响应生命周期开始前的 1009 未处理拒绝：独立 HTTP 请求单轮回退 `/responses`，原生 WS/连接续接无法等价时明确 413，不静默丢上下文。合成验证与真实上游待验收范围见[任务](docs/changes/upstream-ws-body-limit/tasks.md)；官方 Codex 的更高层仍可能重试未识别的 413，见[源码核查](docs/reference/compatibility.md#大请求错误的官方客户端源码核查)。

原生图片首响应期限从上传完成开始。v0.26.11 候选的非流式生成直接请求上游 JSON，仍可聚合提供者主动返回的普通图片 SSE。编辑请求继续使用既有媒体类型和完成事件映射。入站 HTTP 正文采用 10 秒无进度、120 秒总期限，可写连接超时返回 JSON。合成验证与真实格式边界见[慢上游任务](docs/changes/slow-upstream/tasks.md)。

Responses 首响应等待现从本机上传完成边界开始，总执行期限仍覆盖上传；大正文仅记录有界大小/耗时桶。合成验收和传输缓冲边界见[任务](docs/changes/first-response-after-upload/tasks.md)。


实例业务日已支持 `CODEXONE_BUSINESS_DAY_OFFSET`（UTC 或 −12:00 至 +14:00 整小时固定偏移），统一每日限额、统计与 UI，重启采用设置。半小时时区/DST 不支持，到期日期仍用 UTC。业务日窗口及恢复回退验证见[验证记录](docs/changes/business-day/verification.md)。

运行镜像限制 glibc arena 并设置 mmap/trim 阈值，Responses 解析后清空原正文并保留预算租约。发布流程在原生 Linux amd64 验证 768 MiB 下的合成混合容量，范围见[验证指南](docs/development/verification.md)。

首页实时概览默认开启。请求活动、请求输出速率及资源数据由共享快照推送，连接中断自动回退到 HTTP 轮询。范围为首页和首页账号抽屉。见[管理面规范](docs/reference/specs/control-plane.md)与[验收记录](docs/changes/admin-live-updates/tasks.md)。


## 已知限制

v0.26.10将订阅上游已知准入前 `unsupported_backend_parameter/400` 归为无效请求。私有诊断只记录固定字段类别，公开错误和协议限制延续既有契约。见[任务](docs/changes/parameter-rejection-diagnostics/tasks.md)。

- 单节点、单管理员；容器目标为 Linux amd64 Docker Engine。源码开发支持 Linux、macOS 与 Windows（WSL2）。
- 多账号选择机制已有实现，完整多账号路由仍需独立验收；用量和费用可为部分或未知，不用于对外结算或绝对封顶。
- 正文/图片恢复缓存尚未交付；不保证任意断线或重启后恢复已有输出，不自动重放可能已执行的请求。
- 内部协议可能变化。官方客户端标识与 OAuth ID 的使用可能违反提供者条款、触发风控或账号限制，详见[兼容与风险](docs/reference/compatibility.md)。
- v13 数据库需要支持 v13 的程序。回退到 v0.26.15 或更早版本时，使用升级前完整备份独立恢复并核对升级后的执行责任。见[维护指南](docs/guide/backup-upgrade.md)。
- 发版验证在 GitHub Actions 的合成环境中运行；真实订阅、客户端组合与具体服务器容量仍需各自部署验证。

## 路线图

- [管理模型目录与 Key 推理强度](docs/changes/model-catalog-key-reasoning/proposal.md)。
- 重置卡使用与空闲窗口预热的真实订阅验收（需维护者在场确认）。
- [多账号路由治理](docs/requirements/account-routing-governance.md)与故障切换的完整兼容验收。
- [用量分析](docs/changes/usage-analytics/proposal.md)：模型/客户端分布及 CSV。
- [Key 自助查询](docs/changes/key-self-service/proposal.md)：只读、隔离的设备用量入口。
- 暗色模式与交互改进。
- 在可验证的客户端读取契约基础上评估有限恢复缓存。

仍有未完成验证的变更保留在[活动提案](docs/changes/README.md)，不因文档整理标为完成。

## 相关文档

[CHANGELOG](CHANGELOG.md) · [构建与验证](docs/development/verification.md) · [文档导航](docs/README.md)
