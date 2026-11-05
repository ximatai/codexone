# 首页实时概览任务

owner 已确认 [方案](proposal.md)方向；已有默认关闭的实现和本机部分验收，尚未完整交付。S≈0.5—1 人日，M≈1—2 人日；以下按依赖顺序各自可合并，未启用路径保持原 HTTP 行为。总估算 5—7 人日（含评审修订/集成余量），其他页面复用另估；不以此替代实际测量。

- [x] **1. 契约与边界确定（S）**：确认活动事件驱动加对账采样、频率/容量及首版范围；将 v1 envelope、section/freshness、关闭码、Origin/会话活动语义、资源限额同步 control-plane 与 ownership。验收：DTO 合成契约覆盖 null、大整数、业务日/跨日、partial/unavailable；明确长连接是 A10 单响应关闭的精确例外，无 schema/治理或恢复语义变化；不提前宣称交付。
- [x] **2. 独立改善轮询体验（S）**：进行中按采样基准逐秒显示耗时；服务状态后台/手动读取保留旧值、失败标陈旧，保留现有 HTTP 接口。验收：取消/迟到结果不覆盖当前代际；停止刷新时不把旧运行态冒充实时，后台读取不换 loading 整表；稳定行 ID、焦点、抽屉、滚动与 unknown 锁保持。此步可单独交付，无需等待 WS。
- [x] **2b. 显示连续性（S—M）**：按方案引入数字滚动、表格行过渡、进度条与趋势图过渡，HTTP 轮询下即可生效；首屏、恢复、重新可见直接落定，尊重 reduced-motion。验收：真实浏览器大屏和窄屏，合成高频变化下 CLS 为 0、无动画积压，记录包体增量。
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

## 批准时提案检查（历史，非本轮实施验收）

仅静态读代码和文档；未实现、未构建、未运行浏览器/网络/容量验收。本地文档检查 `python3 scripts/check_docs.py` 通过（103 篇 Markdown，仅本地链接/文档结构，不验证运行协议）；`git diff --check` 通过。已复核新增文件及差异仅含设计、代码路径与合成验收计划，无凭证/真实运营数据；上述实施复选框均保持未完成。

## 实际实现与本机验收（2026-11-04）

本轮不是完整交付。1、2 已完成；3、3b、4、5 的实现已进入分组提交，但各任务的全部验收尚未齐全，因此保留未勾选。2b 的数字滚动按 owner 的冲突处理规则暂停；6 的平台/代理矩阵未完成，开关继续默认关闭。未运行 Linux/Docker 构建、SSH、部署实例或真实提供者；未推送、未开 PR、未改版本。

### 实现范围

- 首页及首页账号抽屉：只读 v1 WS；单连接 owner 绑定会话代际，完整 snapshot 后停 HTTP 周期，断连保留数据并恢复轮询，system 也参与刷新；暂停/隐藏/离开关闭连接。账号抽屉共享 headroom，写操作、配置、授权和未知结果锁沿原流程。
- Runtime 监督单一可取消 producer，复用现有 SQLite reader；2/5/15 秒顺序采样，首次及重连完整快照，同值只更新 freshness。每连接实际发送时连续编号；客户端拒绝缺 snapshot、跳号、epoch/版本退步。8 个 viewer/每 session 2 个；队列、帧和关闭有界。
- 准入及 finalize 在 COMMIT 后发布，首事件只在第一次观测时发布；零 viewer 一次原子检查，活动发布 try-lock，不创建任务、SQL 或编码，不抛回执行路径。512 条活动缓冲/单槽唤醒、64 条最近结束、200 条首事件；数据 WS 认证注册/关闭注销，不采集地址、头或会话 ID。finalize 事件标脏聚合，最多每 2 秒更新；5 秒 SQL 对账修复丢失唤醒。没有改变原事务、schema、执行、结算或计量规则。
- 行、进度、趋势过渡及减少动态效果；本地逐秒耗时，稳定的表格/提醒视口，数字仍为精确静态文本。精确锁定 `@formkit/auto-animate@0.10.0`、`@number-flow/react@0.6.2`，补许可；后者目前不渲染，其代码不计作已交付数字动画。
- Nginx 仅精确 live 路径转发 upgrade；Vite 保留 Origin 并启用 WS。`CODEXONE_ADMIN_LIVE=on/off` 配置、Compose gateway 传递、运维/规范/ownership、STATUS、未发布 CHANGELOG 已同步。

### 测量

平台为本机 macOS arm64（Swift 6.4.2、Node 26.13.0、Chrome 156）。以下不能替代 Linux amd64/768 MiB 容器验收。

| 测量 | 实测与边界 |
| --- | --- |
| 请求开始到浏览器 DOM 可见 | 最后一次 60 秒 WS 检查为 **223 ms**；这是提交到 DOM 的上界，含请求执行和 Playwright 可见性等待。没有给 SQLite COMMIT 与浏览器绘制同时插入精确时钟探针，不能声称这是纯 commit-to-paint 延迟。 |
| 观察到提交到 WS 帧/聚合 | 独立本地 socket 检查 **108.68 / 108.69 ms**；HTTP 返回后核对 SQLite settled，再等 WS。请求开始到帧 **114.91 ms**。观察时刻可能晚于真正 COMMIT。 |
| 8 viewer RSS | 200 条边界投影加持续真实 SQLite 准入/结束活动，7 个正常读者与 1 个不读 TCP peer：基线 **21,938,176 B**、峰值 **34,340,864 B**、增加 **12,402,688 B（11.83 MiB）**，小于本机 48 MiB 目标。普通 8 viewer 增加 1,572,864 B。慢 peer 最终强制关闭，阻塞期间未观测到 1013 close 帧，因此只声称 TCP 强制关闭。 |
| 实际 snapshot 帧 | 200 intent 的原始 WS 文本 **237,064 B**，小于 1 MiB；不是 64 账号/256 Key/50 提醒/7 日全部同时取最大值的证明。 |
| 心跳/关闭 | 不回 pong 从建立到关闭 **26.33 s**（15 秒 ping + 10 秒期限，含调度/检查粒度）；正常 1000 回帧通过。优雅关闭 **0.932 s**，观测到 1001。 |
| 60 秒高频 UI | **277 次**合成请求，**CLS=0，long task=0**；真实本地生产 SPA/HTTP/WS/SQLite/假上游；1440×900 和 390×844 无横向溢出；reduced-motion 时活动动画数为 0。最后修改仅暂停时 focus 读取与关闭/取消边界，未再次重复整轮 60 秒检查。 |
| 生产 gzip | 原始基线 `bf306a2` 在当前工作树内隔离目录重建，全部 assets 分别 gzip 后求和：**484,336 → 491,418 B，+7,082 B（6.92 KiB）**。不含尚未启用的 NumberFlow，不能作为完整数字滚动方案的体积承诺。 |

### 实际运行的检查及失败记录

只运行一次完整后端入口和一次完整前端入口；失败后只续跑未执行项、重跑失败项及受后续修正影响的定向检查，没有第二轮完整 macOS 验证。

| 命令/检查 | 实际结果 |
| --- | --- |
| `python3 scripts/check_docs.py`、`python3 scripts/check_architecture.py`、`git diff --check` | 已通过；最终文档收尾后再检查。只证明文档/依赖/差异边界，不是协议验收。 |
| `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` | 格式、构建、**293 个 Swift 测试通过**，此前 **19 个**脚本通过；`verify_text_contract.py` 启动子进程遭 `-9`，无应用输出，整条命令失败。当时有增量重建重叠，原因未确定，不能当作业务故障或成功。 |
| `python3 scripts/verify_text_contract.py --binary …` | 定向复跑通过：HTTP 112、WS 191 个独立合成执行。没有重跑前面已通过的脚本。 |
| 后端剩余命令（`verify.sh` 中 `verify_json_order.py` 至 `verify_migration_cutback.py`） | 原参数顺序续跑 **24/24 通过**，包含新 live 检查。这样 44 个脚本均有通过记录，但原完整命令仍为失败；后续 observation/freshness/取消修正没有重跑全部 44 项。 |
| `swift build -j 12`、定向 `swift test -j 12 --filter 'overview\|liveSessionTouch'` | 增量构建早期 4 次失败：编辑中漏入新源文件、错误配置错误类型、漏枚举 case、probe 给非 optional 限额传 nil；都已修正并构建通过。多轮定向检查通过；最终 **5 个**覆盖 SQLite COMMIT/失败 finalize、零 viewer、1/8 等长窗口读取、最近结束/事件风暴/队列上限、丢唤醒对账、绝对会话期限及取消正在读取的 owner。没有再运行全部 Swift 测试。 |
| `npm … test -- src/features/system-status …` | 首次 78 项中 5 失败（新标签、JSDOM 无 WAAPI、数字包元素行为）；修正后目标模块 **48/48 通过**。 |
| `npm exec --package=node@26.13.0 -- ./scripts/verify.sh --web --chrome` | lint、format、单元 **214/214**、生产构建通过；Chrome **63 通过 / 2 失败**：60 秒 CLS 与既有 Key 固定到期日期失效。保留失败结果，没有重跑完整前端入口。 |
| Chrome 定向 `admin-live-real`、`overview-phase2`、`account-inline` | 真实 WS/HTTP/SQLite/假上游的 60 秒测试及 4 个账号抽屉流程、HTTP fallback/大窄屏通过。实施中的失败包括错误定位、NumberFlow CSP/溢出、CLS 0.019497/0.021136/0.014290/0.014266/0.00008595；每次相关修正均定向复测，最终 CLS=0。一次诊断启动因 preview 端口占用失败。 |
| Chrome 定向 `ui-review-fixes -g 'K03 K04 K06'` | 通过；固定合成时钟后原到期秒保持不变，未修改 Key 产品行为。 |
| Chrome 定向 `admin-live-protocol` | 最终通过：完整 snapshot、同值 metadata 保留内容、跳号回退且保留快照、重新连接后的 1008 经 HTTP 401 清除私有 UI。两次中间失败是测试比较 innerText/textContent 与关闭已退役模拟连接，修正后复测。 |
| `python3 scripts/verify_admin_live.py --binary … --probe …` | 最终真实接口通过：严格 Origin/Host/cookie/混合认证、8/2/第 9 限额、短请求、聚合、native 数据连接注册/断流/结束、替换/登出、控制帧、缺 pong、重启新 epoch/旧 session 401、关闭、开关回退、实际慢 peer/7 个健康 viewer。早期失败分别为 503/429 映射、测试函数名被时间变量遮盖、取消 drain 等待过短、慢端 close 帧被强关截断及测试未接受活动/聚合同帧；均有定向通过。 |
| `npm run build`、lint、format:check、typecheck；`swift format lint --strict --recursive Sources Tests Package.swift` | 当前相关修正已定向通过；生产 build 含 typecheck。构建仍有原有大 chunk/Vite native config 提示，不记为错误。 |
| `python3 scripts/check_backup_compose.py`、部署开关归属检查、`python3 scripts/backend_shards.py --check` | Python YAML/安装 launcher 及 44 脚本归属通过。曾用系统 Ruby 解析，因旧 Psych 不接受原有 flow scalar 失败；没有以它代替 Compose 或运行 Docker。一次手写静态计数把插值中的冒号也计入，改为键检查后通过。 |
| 原始基线隔离重建与 gzip 求和 | 构建通过；目录在工作树忽略产物下，未 checkout/改分支或另建 worktree。 |

### 冲突、未验证与下一步

1. **数字 CSP 冲突已解决**：第二轮已移除 NumberFlow 及其不再需要的依赖，改为本地组件、外部 CSS 和浏览器动画 API；数字文本及读屏值保持真实新值，不放宽 CSP。实时与 HTTP 降级的高频布局、窄屏和 reduced-motion 已通过，见下方第二轮记录。
2. **平台/代理**：没有运行 Linux、Docker、768 MiB 容器；本机 RSS 不能代替该门禁。没有真实 Nginx 管理 TLS/wss、LAN listener/旧代理 30/60 秒矩阵或 Vite 开发代理的完整 upgrade 验收；只有模板静态变更、同源生产 SPA 的直连 ws 与 fallback。完整矩阵之前保持默认 off。
3. **仍缺的失败边界**：真实 upgrade 初始采样中/握手前/各写阶段取消全矩阵；经实际升级连接推进 idle/绝对时钟边界（时钟测试目前在 session owner 层）；实时通道下真实文件系统不可写/恢复与 optional gate；隐藏/重新可见的真实浏览器积压、读繁忙比例/各源耗时与分配器零分配探针；已补 live viewer 的 SIGKILL 新 epoch/旧会话失效/无重放，以及 65 个控制帧突发关闭与健康 viewer/HTTP 存活；持续控制流量的长期测量仍未完成。
4. **最大组合 DTO**：真实 SQLite/WS 测了 200 个合法边界 intent 和实际 frame 上限，尚未把 64 账号、256 Key、50 提醒、7 日同时推至最大。没有凭 payload 算式宣称最大合法 snapshot、共享对象/编码全部内存或 Linux 容器已验收。
5. 后续只需继续上述有据可查的剩余缺项；相关完整任务未勾选，保留 proposal/tasks，不作已交付清理。所有提交均带指定 Co-Authored-By；提交列表以本分支 `git log bf306a2..HEAD` 为准。

## 第二轮：可体验的实时更新与数字滚动（2026-11-05）

已合并已发布的 v0.26.9 修复，数字 CSP 方案按当前提案更新。以下均为 macOS arm64、Swift 6.4.2、Node 26.13.0、Chrome，本机合成 SQLite/管理身份/假上游；不是线上流量或真实订阅验收。

### 功能与体验

- 本地 `ContinuousValue` 以外部 CSS 与 Web Animations API 显示确认后的数字，240 ms，不注入 style 标签。保留完整当前文本供读屏和查询；格式/单位/精度变化、大幅变化及高频打断直接落定，不排队。
- 已移除 `@number-flow/react`、`number-flow`、`esm-env` 及对应许可清单项。未改 CSP。
- 修正提醒数字分段后的可访问链接名称，原对象定位与展开/收起行为保持。
- 实测 HTTP 降级后台失败时旧错误卡会反复推移主内容 86px；改在既有读取状态摘要中提示，展开可看来源、上次成功时间与重试。账号首次失败后的重读保持“尚无成功数据”，不重现初次骨架。失败仍明确，不假装零值或空账号。
- 更新时间明细使用中文来源名；某来源 unavailable 时保留该来源快照并标陈旧，序号异常仍回退 HTTP，401 才清理私有界面。

### 实测

| 项目 | 结果与边界 |
| --- | --- |
| 实时请求到 DOM | 212 ms；真实本地 HTTP 数据请求、SQLite 与管理 WS，到最近结束行可见的上界，不是纯 COMMIT-to-paint。 |
| HTTP 降级请求到 DOM | 稳定轮询阶段 12,651 ms；实际 HTTP 统计读取，WS 故障由浏览器路由合成。轮询等待受采样相位影响，不是固定延迟或 SLA。 |
| 实时 60 秒 | 278 次合成请求、215 次数字动画、CLS=0、long task=0、无 CSP 违规、数字下无 inline style。 |
| HTTP 降级 60 秒 | 273 次合成请求、15 次数字动画、CLS=0、long task=0、无 CSP 违规；此前发现并修复 CLS 0.1620758 和 0.0170370 两处真实布局回归，没有放宽阈值。 |
| 大/窄屏 | 1440×900 与 390×844，无页面横向溢出；reduced-motion 后 0 个运行中动画。数字伪元素确实绘制当前字符，读屏分支保留完整新文本。 |
| 包体 | 在临时隔离目录从 `ea623ef` 重建原静态数字基线，复用相同已安装的其余锁定依赖；同一 Python gzip(level 9) 对全部 assets 求和：491,418 → 492,767 B，+1,349 B（1.32 KiB）。未安装或打包已不被基线引用的 NumberFlow。 |
| viewer 强杀/恢复 | 活跃 viewer 下真实 SIGKILL 后启动新进程：旧 cookie 401、新 epoch/完整快照、近期结束和连接列表不回放，attempt 数及提供者连接数不增加。未把它扩展宣称为已覆盖所有写帧取消竞态。 |
| 控制帧限额 | 65 个真实 masked ping 突发触发 1008；健康 viewer 继续收到更新，HTTP 管理可用，替代连接能取得已释放 slot。不是持续长期流量基准。 |
| 慢端与资源 | 200 intent + 7 个健康 viewer + 1 个不读 TCP peer，慢端被强制关闭、其他端存活；额外 RSS 11,517,952 B；snapshot 237,064 B。不是最大组合 DTO 或 Linux 768 MiB 容器验证。 |
| 传输观测 | 观察到 SQLite 结算后至 WS 帧约 103 ms；不回 pong 25.31 s 关闭，优雅停止 1.042 s 并收到 1001。 |

### 命令与失败记录

- `swift build --build-tests -j 12` 通过；本轮未重复整套 macOS 后端。`verify_admin_live.py --binary … --probe …` 的认证/限额/提交活动/替换登出/心跳/强杀/关闭/慢端检查通过；新增控制帧场景单独通过，CI 的同脚本会包含它。
- `./scripts/verify.sh --web --chrome` 首次 lint/format 通过，单元 215/216，因旧测试假设 title 与数字文本在同一节点失败而退出。第一次改为 title 查询仍匹配多行而失败，进一步限定到目标行的数值容器；本轮读取失败布局修改后，最终完整单元回归 216/216 通过。新增数字组件 2 测试及受影响管理概览测试定向通过；后续完整单元回归用于覆盖新增读取失败布局修正，没有重复整个 verify 入口；原命令仍记失败。
- 续跑 build（含 typecheck）通过；首次完整浏览器轮次 63/66，两个同类旧 title 选择器失败，另一个跨多页并截图的流程在 7 worker 下碰到 15 秒总期限。修正选择器、给该长流程 30 秒总预算但保留单动作断言期限；失败项单独 4/4 通过，随后本轮受影响的 23 个浏览器测试全部通过。
- 真实栈单独 60 秒检查先发现数字与标点宽度不同的轻微 CLS，统一字符槽后实时模式通过；后加 HTTP 降级检查又发现错误卡与首次失败骨架反复出现，修复后 HTTP 60 秒亦通过。上述失败都保留为过程证据，没有修改 CLS=0 要求。
- 最新 source unavailable/快照保留/序号回退/撤销、提醒/Key/账号抽屉/导航及快照错误场景 23/23 通过；lint、格式、typecheck/生产构建与文档检查通过。新应用改动后只复测受影响项，没有重复整个浏览器集合。

### Linux CI 接线修正

首轮 PR CI 的普通前端容器没有 `.build/debug/codexone`，真实栈的两个浏览器场景在启动合成后端时 FileNotFoundError；不是应用断言通过。现将普通 `frontend` 的 65 个隔离场景与独立 `frontend-live` 的两个真实网关/浏览器场景分组；后者在同版 Swift 容器中消费同次构建产物。后端或前端改变都会构建网关并要求真实栈任务成功，最终 gate 不接受跳过；普通前端的排除不意味着总流程跳过。10 个 CI 策略回归测试通过，列表实测分别为 65 和 2，完整 Linux 重跑仍待结果。

第二轮 Linux CI 的普通前端、真实栈两个浏览器场景、Swift 构建/测试、文档、开发容器和后端第 1/2/3 分片均通过；第 4 分片在 HTTP 200 后立即断言 SQLite 已 settled 的测试竞态再次失败。响应结束不等待异步 finalizer；测试现以最多 5 秒轮询真实 SQLite settled 作为观察起点，仍要求实际结算和随后推送，不修改应用事务/期限或放宽事件内容。本机该协议段和控制帧段复测通过；慢端段首次因误填 probe 名未启动，不能计通过。Linux 最终门禁仍待此修正推送后的结果。

首轮 Images 超时断言未包含实际状态；现补错误状态与固定 code 作为失败诊断，不改变原 408/期限/不派发要求。第二轮 Linux CI 原测试通过；另用 CI 构建的 Linux amd64 二进制，在本机隔离 Docker/Rosetta、非 root、断外网、2 GiB/2 CPU 下完整 Images HTTP/WS 检查通过，未复现首次失败。没有据此猜测原因或改生产逻辑，也不将模拟运行算作原生 Linux 容量证明。

### 当前交付边界

技术显示连续性验收已完成，可用本地合成预览看手感；完整共享 sampler、认证/寿命失败矩阵、最大组合 DTO、真实代理及 Linux 容器门禁仍按上方未勾选任务推进，`CODEXONE_ADMIN_LIVE` 默认仍为 off。没有部署到线上，不能将本地预览写成发布完成。

### 真实管理 TLS/代理补测

- 本机 Nginx 1.31.8、OpenSSL 3、独立临时 CA/prefix/端口与合成网关；不启用系统服务、不更改系统信任或线上 Nginx。
- 实际 WSS 返回 v1/sequence 1/八来源完整 snapshot；缺 cookie、错误 Origin/Host、混合 Bearer、query 及数据监听面不能升级。管理登出使原 TLS viewer 收到 1008。
- 只删除临时管理模板的精确 upgrade 路径，等待代理 reload 真正生效：WS 不能升级，同一会话 HTTPS 仍 200；恢复后可重新取得完整快照。30/60 秒 read idle 配置下，原 socket 跨过窗口并分别收到 2/4 次心跳，随后 masked ping/pong 双向通过。期间有 freshness 帧，不将其归为仅靠 ping 保活；不是线上代理验收。
- 浏览器补测先揭示旧脚本与现有 Key 创建按钮、详情抽屉、禁用确认、默认可用筛选和刷新行为不匹配，逐项按当前界面修正。没有改产品来适应旧断言。
- 最终 `verify_tls_proxy.py --binary … --web web/dist --nginx … --openssl … --browser` 退出 0：上述 30/60 秒、旧模板/恢复、认证/登出检查，以及 Chrome 直连 HTTPS 登录/实时连接/创建/禁用/刷新/退出、数据 HTTP/SSE/WSS、取消/中断结算、超时无重放与故障清理全部通过。浏览器仅固定临时叶证书 SPKI，链/主机名错误另由实际 TLS socket 验证拒绝；没有降低应用 CSP 或授权要求。
- SQLite 结算观察修正后，本机协议段与控制帧段通过；慢端补跑改用实际 `ExecutionProbe` 后通过：200 intent、7 个正常 viewer/1 个不读 peer，snapshot 237,064 B，额外 RSS 12,812,288 B，健康 viewer/HTTP 存活。未观察到慢端关闭帧，仍只声称强制关闭；不是最大组合或原生 Linux 容量验证。

## 相关文档

[方案](proposal.md) · [管理规范](../../reference/specs/control-plane.md) · [验证约定](../../development/verification.md)
