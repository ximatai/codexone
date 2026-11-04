# 首页实时概览任务

owner 已确认 [方案](proposal.md)方向，尚无实现验收。S≈0.5—1 人日，M≈1—2 人日；以下按依赖顺序各自可合并，未启用路径保持原 HTTP 行为。总估算 5—7 人日（含评审修订/集成余量），其他页面复用另估；不以此替代实际测量。

- [ ] **1. 契约与边界确定（S）**：确认活动事件驱动加对账采样、频率/容量及首版范围；将 v1 envelope、section/freshness、关闭码、Origin/会话活动语义、资源限额同步 control-plane 与 ownership。验收：DTO 合成契约覆盖 null、大整数、业务日/跨日、partial/unavailable；明确长连接是 A10 单响应关闭的精确例外，无 schema/治理或恢复语义变化；不提前宣称交付。
- [ ] **2. 独立改善轮询体验（S）**：进行中按采样基准逐秒显示耗时；服务状态后台/手动读取保留旧值、失败标陈旧，保留现有 HTTP 接口。验收：取消/迟到结果不覆盖当前代际；停止刷新时不把旧运行态冒充实时，后台读取不换 loading 整表；稳定行 ID、焦点、抽屉、滚动与 unknown 锁保持。此步可单独交付，无需等待 WS。
- [ ] **2b. 显示连续性（S—M）**：按方案引入数字滚动、表格行过渡、进度条与趋势图过渡，HTTP 轮询下即可生效；首屏、恢复、重新可见直接落定，尊重 reduced-motion。验收：真实浏览器大屏和窄屏，合成高频变化下 CLS 为 0、无动画积压，记录包体增量。
- [ ] **3. 共享 sampler 与快照（M）**：Runtime 管寿命、Adapters 组装 DTO，使用既有 reader/观察，尚不启用 WS；一份缓存、顺序 2/5/15 秒调度、变化与 freshness 合并、总 3 MiB 缓存/编码预算。验收：经真实 SQLite 接口证明 1 与 8 viewers 在等长窗口查询数相同（允许初始采样边界差），新 viewer 不触发聚合；最后离开取消并 await、随后无本功能查询/timer；快速重连不生成第二 producer。busy/超时/optional gate 保留旧值与安全状态，不能重试风暴或启动新 reader；最大合法 64 账号/256 Key/200 intent/50 提醒/7 日合成 DTO 检查 1 MiB 消息界限，超限走明确降级。
- [ ] **3b. 活动事件（M）**：提交后非阻塞发布进行中活动，含最近结束缓冲和已连接客户端注册表；finalize 将聚合标脏并节流重算；5 秒对账。验收按方案“活动的即时性”的失败场景，经真实 SQLite 和数据面连接，测提交到浏览器延迟。
- [ ] **4. 管理 upgrade、认证与有界连接（M）**：仅精确路由启用专用 NIO upgrade，连接注册/注销绑定 AdminSessions；保留 HTTP ingress 的大小、期限、连接上限。实现部署开关，默认关闭直到集成就绪。验收：本地真实 TCP/HTTP upgrade+WS 客户端验证正确 cookie/Origin 可连；缺/异源/null/重复 Origin、错误 Host、混合 Bearer、普通 Key、重复 cookie、query 均拒绝；连接/每 session 限额有效，满载时登录/登出仍可用。检查无秘密进入 URL/日志、无应用入站/压缩/无界分片；连续控制流量不能突破缓冲/任务边界。
- [ ] **5. 首页接入与可用性降级（M）**：单连接 owner 绑定 session generation；完整 snapshot 后切换 Query 数据来源，合并 section、逐源 freshness，首页账号抽屉取消重复 headroom interval。验收：初始/断连/恢复/跨日/协议错误/序号异常按方案显示；WS 不可用时 HTTP 15 秒兜底，system 也重读；退避/60 秒探测不同时开多连接，重连不重放写操作；隐藏/暂停/离开/会话退役及时关连接并取消 fallback，旧 HTTP/WS 不覆盖新代际；401 清数据，网络失败不误登出，mutation 未知锁不被推送解除。
- [ ] **6. 代理与端到端失败验收（S—M）**：默认启用前更新管理 Nginx 精确路径、Vite WS 代理、TLS/部署/回退文档；保留未更新代理的安装兼容。验收以下真实接口矩阵，并完成相关定向/标准检查；失败即保持默认关闭，不以 helper 或合成编码成功替代网络结果。

## 第 6 步验收矩阵

全部只使用合成账号、管理员秘密、SQLite 临时库、假上游和本地进程/反代；“真实接口”指实际 TCP/HTTP/WS/文件系统/浏览器边界，不使用真实订阅、OpenAI、SSH 或已部署实例。

| 场景 | 操作与通过条件 |
| --- | --- |
| 取消、断流 | 握手前/初始采样中/写帧中取消，客户端正常 close、拔断 TCP、半开不回 pong；10 秒心跳期限、5 秒写期限有效，释放 slot/队列/Task；单人断开不取消其他 viewer，最后一人退出不再采样。 |
| 慢客户端 | 实际不读取 socket 并持续产生最大合法变化，观察 NIO 写缓冲及应用队列；每人最多 2 MiB 待发+1 MiB 在途，超界 1013/强制关闭；正常 viewer 与 HTTP 管理不被阻塞，服务端内存有界。 |
| 会话期限/撤销 | 通过可控时钟推进 idle/绝对边界、正常 HTTP 续期、logout、同 cookie 重新登录替换及其他标签页撤销；过期/撤销后不可再发数据，连接关闭并由 HTTP session 核对回登录。活跃订阅按既有轮询语义维持 idle，绝对 7 天不延长；不以 ping 自动恢复已撤销 session。 |
| 并发与存储压力 | 1/8/第 9 viewer、单 session 第 3 连接、与 HTTP 统计争 reader、快速连接退出；查询次数不随 viewers 增长，32 总连接/16 管理并发边界不被长连接占尽。SQLite/目录变不可写并触发 optional gate：storage 与 source unavailable 可见、旧数据带时间，无假零值；核心写入/finalizer/unknown 路径不被采样绕过。恢复可写后能恢复采样。 |
| 重启/关闭 | 真实进程 graceful stop 和强杀后重启，连接全部释放，sampler 在 reader/DB 关闭前结束，5 秒关闭上限；会话失效、新 epoch/完整 snapshot，无旧数据覆盖、无生成重放/事件回放承诺。 |
| 代理和回退 | 本地管理 TLS Nginx 转发 upgrade、直连 LAN 合成模式、旧模板删除 upgrade、代理 30/60 秒 idle、服务不可达、开关关闭、旧后端 404；wss/ws 与 CSP 实际可用，回退 HTTP，重连退避符合方案。Host/Origin 不改写绕过；数据 listener 不暴露管理 live。 |
| 容量 | Linux amd64、768 MiB 容器中合成混合数据面+8 viewers+慢端；记录额外 RSS、队列/缓存峰值、各源查询耗时/频率、读繁忙比例和关闭耗时。新增 RSS ≤48 MiB、无 OOM/核心饥饿；不通过则调整界限/聚合频率后重验，不凭 payload 算式声称通过。 |
| 浏览器 | 合成 API+真实本地 WS，至少 1440×900 和 390×844；操作登录/暂停/恢复/手动刷新、首页账号抽屉/滚动/焦点、Key 失败跳转、断网/代理拒绝/重启/会话失效。核对更新不整表闪烁、行身份和抽屉草稿保留、屏幕阅读提示不过度逐秒播报、逐源陈旧/业务日/未知值及轮询模式清楚；截图仅合成数据。 |

实现验收按 `CONTRIBUTING.md` 运行 `python3 scripts/check_docs.py`、`./scripts/verify.sh --backend`、`./scripts/verify.sh --web --chrome` 及相关 lint/format/tests；平台、命令、结果与未验证项写入本任务的实际验证，完成后归纳规范并按变更约定回收过程文档。不把真实提供者兼容作为此只读管理通道的前置验收。

## 本次提案检查（2026-11-04）

仅静态读代码和文档；未实现、未构建、未运行浏览器/网络/容量验收。本地文档检查 `python3 scripts/check_docs.py` 通过（103 篇 Markdown，仅本地链接/文档结构，不验证运行协议）；`git diff --check` 通过。已复核新增文件及差异仅含设计、代码路径与合成验收计划，无凭证/真实运营数据；上述实施复选框均保持未完成。

## 相关文档

[方案](proposal.md) · [管理规范](../../reference/specs/control-plane.md) · [验证约定](../../development/verification.md)
