# 项目状态

公开能力范围、已知限制和后续方向的简明入口。

## 版本与能力

当前版本为 **[v0.26.9](https://github.com/ximatai/codexone/releases/tag/v0.26.9)**（2026-11-05），核心数据库 schema v11。镜像发布在 GHCR `ghcr.io/ximatai/codexone`（Linux amd64），附来源证明；也可以从源码构建。

项目是个人自托管网关：管理自己的 ChatGPT/Codex 订阅账号，为自己的多台设备和工具分别发放 Key。已实现账号授权/刷新与额度观察、Key 权限/轮换/归档/全部模型范围、本地限额和用量诊断、Responses HTTP/SSE/WS 与桥接、预热/压缩、原生图片生成/参考图编辑、同源管理面板、快照备份和维护迁移；v0.26.2 起提供设备码授权、可选局域网 HTTP 模式与网关自动重启；v0.26.4 起提供订阅重置卡查看/确认使用/到期前自动使用，以及空闲 5 小时/每周配额窗口预热（均按账号默认关闭）。

v0.26.5 起重置卡自动使用支持分钟级提前量和有界分钟重试，未知结果沿原请求 ID 核对；v0.26.6 起上游过载统一递增节流并支持准入前有界等待，429 与认证屏障不变；schema 仍为 v11。

托管 Key 策略仅接受每日 Token 与最大并发，旧请求次数不换算；升级前须保存完整 bundle，写入新策略后不能原库回退至 v0.26.5 及更早版本，见[Key 回退前提](docs/guide/key-governance.md#兼容回退前提)。

从 v0.26.3 及更早版本升级须按[维护指南](docs/guide/backup-upgrade.md)停服备份迁移到 schema v11，v10 及更旧程序拒绝 v11。

上游订阅 HTTP 大请求新增有界 zstd 上传与 `off` 回退；响应事件前 415 仅同账号明文重发一次。版本号不变，Linux/真实上游及内存发布门禁见[验证记录](docs/changes/upstream-zstd/verification.md)。

共享正文预算放宽至 64 MiB，普通正文统一计量、另保留 8 MiB 小请求余量及短时等待及默认开放 GIF/SVG（沿图片权限与模型范围）正在开发，尚未发布；首轮已拆分协议内容、Adapter 事实与执行风险，修复 Responses 输出 codec 耦合、用量扩展回传及 WS 队列容量隔离；现补齐 SVG 作者计量及独立价格覆盖（开发 schema v12，升级需显式迁移，不能用 v0.26.9 原库回退）；仍待新的 Linux、混合负载与真实客户端验收。业务边界、验证和回退见[活动提案](docs/changes/protocol-alignment/proposal.md)。

## 管理界面与 Token 治理

首页大数按万/亿/万亿展示并保留精确值提示，容量以进度条区分参考阈值与阻断上限；今日未归档托管 Key 的成功、失败、取消、执行中与结果未明汇总（仅今日有准入，停用状态明确标注）替换最近请求明细。大屏拓宽侧栏并合并运行状态，参考阈值随指标卡展示、账号并发随订阅账号展示，普通提醒与空状态精简。只读摘要新增成功、取消与在途计数，无 schema 变化。本机定向验证与平台边界见[验证记录](docs/changes/overview-summary/verification.md)。 首页账号入口现就地打开复用的详情抽屉，保留首页导航、滚动与历史恢复；详情按概览/自动化/设置分组，固定头部、按需读取配置并保留页签间草稿；账号设置只提供启用/禁用；手动使用重置卡仅保留各卡自己的使用按钮与确认；精简重复说明，由分组与数字列传达信息，保留异常和操作后果提示。进行中列表现按 Key、模型/模式、推理强度、订阅账号、运行时长与首事件拆列，强度来自既有账本字段，区分未指定与历史未记录。6 个账号、10/20 条进行中请求的合成复核仍发现首页过长，账号与请求列表的紧凑展示、有界展开待优化。

访问密钥默认筛选可用，“全部”包含已归档；列表精简为身份、权限、状态、用量与最近使用，详情抽屉统一查看与管理操作；Key配置仅每日Token上限与最大并发，单位切换保留数量；根据已观测Token阻止后续准入，不保证绝对封顶，旧请求次数不自动换算；用量摘要以Token为主，费用收至统计明细。凭证安全规则不变。

每日Token限制的验证与平台边界见[验证记录](docs/changes/daily-token-limit/verification.md)。

v0.26.7 起统一跨传输会话软亲和与双向协议元数据；真实续接 token 独立约束来源，未知状态明确拒绝；辅助 5xx 按端点隔离，429/401 保留账号级保护。契约与验收见[会话路由任务](docs/changes/session-routing-metadata/tasks.md)。

v0.26.8 起网关保留 JSON 对象键顺序，相同请求发往上游的正文稳定；真实提示缓存验收见[任务](docs/changes/preserve-json-key-order/tasks.md)。

上游 WS 大请求现按最终编码消息预检：独立 HTTP 调用超过 12 MiB 预先走 HTTP，原生 WS 超过同一 12 MiB 阈值沿既有路径拒绝，并识别响应生命周期开始前的 1009 未处理拒绝：独立 HTTP 请求单轮回退 `/responses`，原生 WS/连接续接无法等价时明确 413，不静默丢上下文。合成验证与真实上游待验收范围见[任务](docs/changes/upstream-ws-body-limit/tasks.md)；官方 Codex 的更高层仍可能重试未识别的 413，见[源码核查](docs/reference/compatibility.md#大请求错误的官方客户端源码核查)。

原生图片首响应期限现同样从上传完成开始；generations 非流式客户端由上游 SSE 聚合 JSON，edits 请求上游非流式并可转为客户端完成事件。入站 HTTP 正文采用 10 秒无进度、120 秒总期限，可写连接超时返回 JSON。合成验证与真实格式边界见[慢上游任务](docs/changes/slow-upstream/tasks.md)。

Responses 首响应等待现从本机上传完成边界开始，总执行期限仍覆盖上传；大正文仅记录有界大小/耗时桶。合成验收和传输缓冲边界见[任务](docs/changes/first-response-after-upload/tasks.md)。

首页 Key 面板现按最近活动排序，展示请求/失败/Token/缓存六列；失败采用 20/5/20% 橙色提示和精确 outcome=failed 跳转，缓存率排除无用量请求，缺失以提示说明。只显示今日活跃未归档 Key，无“全部”切换。验证见[业务日与面板记录](docs/changes/business-day/verification.md)。

实例业务日已支持 `CODEXONE_BUSINESS_DAY_OFFSET`（UTC 或 −12:00 至 +14:00 整小时固定偏移），统一每日限额、统计与 UI，重启采用设置，schema 仍 v11。半小时时区/DST 不支持，到期日期仍用 UTC。业务日窗口及恢复回退验证见[验证记录](docs/changes/business-day/verification.md)。

大请求后内存保留正在修复：运行镜像限制 glibc arena 并设置 mmap/trim 阈值，解析后清空 Responses 原正文但保留预算租约；本机合成验证与 CI 新镜像待验收范围见[任务](docs/changes/memory-retention/tasks.md)。

首页实时概览已实现可显式启用的本地集成路径（默认关闭）：提交后活动、最近结束、已连接客户端、共享 sampler 及 HTTP 降级，仅覆盖首页和首页账号抽屉。数字滚动现使用本地组件和外部静态样式，已移除不兼容组件，不放宽 CSP；本地浏览器真实请求更新与高频布局验收已通过，完整交付与平台验收尚未完成，见[活动任务及实测](docs/changes/admin-live-updates/tasks.md)。无 schema 或执行/用量行为变更。

评审优化已接入有时限的单请求关注/固定观察、账号及按 Key 诊断入口、当前本地接入条件摘要和持续 WS 连接范围说明；来源不可用、模块陈旧及 HTTP 更新时间统一处理。剩余原生 Linux/容量与失败矩阵按活动任务验收，不能据此宣称默认启用或已发布。

## 已知限制

订阅参数拒绝诊断正在修正：新增准入前 `unsupported_backend_parameter/400` 按 invalid_request 统计，私有日志使用固定字段类别定位原因，不记录参数值，不修改公开错误或协议限制。验证进展见[任务](docs/changes/parameter-rejection-diagnostics/tasks.md)，尚未发布。

- 单节点、单管理员；容器目标为 Linux amd64 Docker Engine。源码开发支持 Linux、macOS 与 Windows（WSL2）。
- 多账号选择机制已有实现，完整多账号路由仍需独立验收；用量和费用可为部分或未知，不用于对外结算或绝对封顶。
- 正文/图片恢复缓存尚未交付；不保证任意断线或重启后恢复已有输出，不自动重放可能已执行的请求。
- 内部协议可能变化。官方客户端标识与 OAuth ID 的使用可能违反提供者条款、触发风控或账号限制，详见[兼容与风险](docs/reference/compatibility.md)。
- v11 不能使用 v10 或更旧程序原库回退；升级、备份恢复与迁移须按[维护指南](docs/guide/backup-upgrade.md)执行。
- 发版验证在 GitHub Actions 的合成环境中运行；真实订阅、客户端组合与具体服务器容量仍需各自部署验证。

## 路线图

- 重置卡使用与空闲窗口预热的真实订阅验收（需维护者在场确认）。
- 多账号路由与故障切换的完整兼容验收。
- [用量分析](docs/changes/usage-analytics/proposal.md)：模型/客户端分布及 CSV。
- [Key 自助查询](docs/changes/key-self-service/proposal.md)：只读、隔离的设备用量入口。
- 暗色模式与交互改进。
- 在可验证的客户端读取契约基础上评估有限恢复缓存。

仍有未完成验证的变更保留在[活动提案](docs/changes/README.md)，不因文档整理标为完成。

## 相关文档

[CHANGELOG](CHANGELOG.md) · [构建与验证](docs/development/verification.md) · [文档导航](docs/README.md)
