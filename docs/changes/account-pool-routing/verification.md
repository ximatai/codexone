# 验证与复盘

## 2026-10-22 · 托管 dispatch 准入屏障

主 Agent 亲自实现/复盘，macOS arm64 / Swift 6.4。`./scripts/verify.sh --backend` 完整通过：84 个 Swift 测试函数与全部进程/HTTP/SSE/WS/Key/session/账号脚本。本切片未改前端，不新增浏览器通过声明。

新增四项真实 Crypto/SQLite 测试：准备凭证后禁用/开始刷新/重新授权会使旧快照拒绝且不存在 attempt；实际等待原访问期限过期后也拒绝。enabled/ready 与 draining 可信续接分别验证，disabled/过期 access 不会准备可派发 work；缺账号快照的匹配旧路径拒绝，安全快照持久往返无 token。Key 撤销与账号快照在同一准入事务复核，拒绝不留 attempt；正确准入后普通禁用仍允许绑定与如实结算，不能擦除已有责任。

v3 构造保留执行 intent 与 refreshing 账号，普通启动明确拒绝；显式迁移生成私有 pre-v4 备份，真实打开备份验证源版本 3/intent/refreshing 均未提前恢复。v4 普通启动再变 unknown/auth_uncertain，历史 admission.accountSnapshot 为 nil，重复迁移没有第二个完成备份。旧 v1/v2 的 Key 保留/一致性备份和迁移中断事务回滚继续通过；进程脚本更新为 v4 并完整重跑，包括三组账号 SIGKILL。备份文件计数仅纳入完成的 .sqlite，不能把打开备份时产生的 WAL 辅助文件当额外备份。

此切片只建立持久屏障，尚未把账号选择接入 HTTP/WS，continuation 由后续应用归属/连接核实，不由客户端提供。未测试真实订阅/额度/生产 TLS，不代表账号池可路由或 M3 整体完成。提交后 review 与 Linux 结果待对应提交完成后记录。


f488da5 独立 review 无需修复或阻塞，reviewer 独立运行新增四项真实 SQLite 测试全部通过。该精确快照 Linux amd64 / Swift 6.4 本地单并发容器完整后端 84 测试与全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。仅持久屏障验收，不推导选择器/传输或真实订阅。


主 Agent 后续自我复盘发现 namespace 边界不一致：可信凭证上下文允许 512 字节，旧准入/指定 namespace 的归属查询却混用 256 字节标识校验。亲自统一 namespace 上限至 512，其他标识保持 256（管理账号/Key 仍各自 64）。新增真实 Crypto/SQLite 最长 namespace 的准入、绑定、指定 namespace 读取与跨主体拒绝，以及 257 字节 attempt 继续拒绝。macOS 完整后端 85 测试与全部脚本通过；689fdc9 独立 review 无阻塞，reviewer 定向回归通过；同快照 Linux amd64 / Swift 6.4 单并发完整后端 85 测试及全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。


## 2026-10-22 · 有效 access 的原子选择用例

主 Agent 亲自实现并复盘；七项新增真实 Crypto/SQLite 与 Runtime 测试通过。两个并发准入观察当前 intent 后选择不同账号；结算后固定 seed 的分流在重新打开 DB 后一致。归属测试覆盖跨账号同名对象、多个引用交集、连接消歧、跨主体与不一致连接拒绝；准备后新增同名绑定在准入事务拒绝，禁用全部候选和撤销 Key 均不留新 attempt。draining 的伪造无归属 continuation 拒绝，已有引用可续接；全局容量不足不换账号循环。

实际 Core 池用例使用受监督 finalizer：一个执行保持在途时另一个选择其他账号；第二执行观察部分用量后失败，仅调用一次并最终 unknown，已观察用量保留；已有 response 续接回原账号。所有收尾容量占满时，准备闭包调用数为零；过期 access 返回需要刷新且未执行生成，ticket 无泄漏。复盘提取共用 SQL 准入事务与 Core 收尾所有权，避免两个入口出现不同治理或 orphan intent。

本切片没有把 HTTP/WS 数据面连接池用例；过期/正在刷新候选与共享刷新 owner 的衔接、健康/额度仍待后续实现。无真实订阅或额度调用，也没有新增前端/浏览器验收声明。macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend` 通过，92 个 Swift 测试函数及全部脚本；6074b3d 独立 review 无阻塞，reviewer 七项定向回归通过；同快照 Linux amd64 / Swift 6.4 本地单并发完整后端 92 测试及全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。


## 2026-10-22 · 共享刷新的路由衔接

主 Agent 亲自实现和复盘，新增四项真实 SQLite/Runtime 回归通过。管理刷新已经持久 begin intent 后，路由携当前更高 revision/同 credential version 仍加入同一工作；错误版本及用更新 revision 伪装管理重试拒绝。取消一个路由等待者不会取消共享 provider；独立持久 refreshing 而无 Service owner 的状态拒绝且不会再请求 provider。

实际池用例中两个过期账号只刷新一个；两个请求共享一次刷新，取消一个立即归还无 intent 的执行 ticket，另一个在新凭证提交后唯一派发，另账号版本不变。明确重新授权失败及未知失败分别保留 requires_auth/auth_uncertain，不向第二账号刷新，也没有生成调用。刷新期间账号禁用或 Key 撤销后，已接受刷新照实提交新版本，但执行重新检查后拒绝，操作闭包调用为零。旧管理单飞和取消测试继续通过。provider 为无凭证合成端口实现，此处不声称真实网络/TLS/订阅验收。

macOS arm64 / Swift 6.4 完整后端 96 测试及全部脚本通过；6c33cad 独立 review 无阻塞，reviewer 四项新增回归通过；同快照 Linux amd64 / Swift 6.4 单并发完整后端 96 测试及全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。HTTP/WS 接入、健康/额度仍未完成。


## 2026-10-22 · 订阅数据认证装配

主 Agent 实现两项回归，实际合成 OAuth socket 登录后保存/启用/解密 work，再检查临时 Bearer/account 头与脱敏表示。生产和合成 realm/namespace 互换、生产 work 送合成目标、无效 loopback 端口均拒绝；生产 origin 仅在不发网络的合成可信存储 fixture 上检查固定值。另一项覆盖 access 的账号/subject/namespace 变化、缺 ID、过期 access 拒绝及过期可信 ID 基线仍允许；验证阶段没有发送任何数据生成请求，OAuth POST 次数始终为一次。

协议认证头依据 OpenAI Codex 公共 bearer auth provider 核实，未复制架构或实现；纯范围/装配验收不代表数据传输、生产 TLS 或真实订阅通过。macOS arm64 / Swift 6.4 完整后端 98 测试及全部脚本通过；bd46a59 独立 review 无阻塞，两项定向回归通过；同快照 Linux amd64 / Swift 6.4 本地单并发完整后端 98 测试及全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。

## 2026-10-22 · HTTP 池入口与生产装配

主 Agent 实现、验证并自我复盘。macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend` 通过：106 个 Swift 测试函数、所有旧进程/HTTP/SSE/WS/context/压缩/Key/session/账号脚本，以及新私有池配置脚本。没有前端代码变更或新增浏览器通过声明。

六项新增池 HTTP 测试使用真实 NIO loopback 提供者、URLSession 下游和实际 Runtime/SQLite/AEAD。两个合成 OAuth 登录导入两个隔离 namespace；JSON、SSE、独立 compact 真实转发并结算，跨主体与未知 previous ID 在发往上游前拒绝，续接固定原账号。下游伪造 account/私有头不透传，提供者只收到所选 access/account。并发保持一个在途时选择另账号；提供者直接断开只发送一次，持久 unknown，不切账号重放。禁用原账号不能把续接移往其他账号，新无归属请求可用剩余账号；Key 撤销返回 401 且不派发。

另外以实际合成 token socket 刷新已过期的固定账号，凭证版本在重新授权和共享刷新后递增到 3，原 namespace/续接保留、最终认证头使用新 access，严格计数为两次登录加一次刷新。下游取消归还执行容量并留下 unknown；终态只有部分 usage 时保留已观察成本和 unknown，不冒充结算。复盘先前测试夹具遗漏 cached_tokens 导致完整度应为 partial，修正完整 fixture 并另保留实际部分用量用例，未弱化产品完整度规则。

新增配置/运行约束两项测试及真实进程脚本：拒绝上游地址、token、headers、WS 等未支持根字段；复用完整模型/profile 校验；要求独立主密钥/管理凭证/数据目录，与旧身份配置互斥。私有文件权限校验和 `--check-config` 均不建库/发网络。生产固定目标的空池在数据/管理口 live 200、ready 503；账号列表安全、无 Key 生成请求 401；实际关闭/重开及端口释放通过，无任何提供者请求。

提取共享 Responses 配置与两种真实授权来源，单身份配置与模型校验保持兼容；复用解析/证据/绑定/收尾代码，避免复制第二套协议执行器。AHC 显式关闭重试/重定向/代理继承/解压，单次连接 HTTP/1。管理与数据的健康查询异步读取同一当前账号视图。池 native WS、HTTP→WS、健康/额度及真实订阅仍未完成；不能用原单身份 WS 脚本为池 WS 背书。提交后 review 与同快照 Linux 待补记。

## 2026-10-22 · HTTP 提交后复核与修复

d8e368a（状态补齐 81046d1）独立 review 发现两项 P2。主 Agent 亲自修复：有效模型保留目录顺序，只有价格摘要单独排序；两模型反序及指导变化均改变策略版本，价格版本不变，实际目录顺序与摘要一致。池 readiness 增加 Core 有界本地 AEAD 可用性检查，至多 64 个候选逐个验证、不缓存明文、不发网络或改授权状态。派发也跳过局部解密失败，关键存储故障继续拒绝。

新增两项实际池服务健康测试：保存后关闭/重新打开合成库，以错误主密钥组装服务，ready 503、生成拒绝且没有上游请求；逐个篡改结构合法信封的认证数据，一个坏账号时另账号仍 ready 200 且实际派发，全部坏后 ready/生成均 503，账号授权元数据不变。合法可解密的过期 access 仍 ready，可由已有刷新 owner 处理，不误写 requires_auth。

macOS arm64 / Swift 6.4 最终完整后端 109 测试和全部脚本通过。独立 reviewer 此前重跑原八项定向测试、私有配置进程与旧 HTTP 协议回归均通过；修复提交后须复审，不能提前关闭两项 P2。

原 HTTP 快照的 Linux 尝试未计通过：复用验证卷残留改名前文件导致输入错误，重新铺入干净源码后，独立夹具并行初始化又使 500 ms OAuth 登录超时。标准命令现显式串行独立 Swift case，各 case 内并发竞争/取消保持不变，不放宽期限断言；后续验证卷只保留编译缓存再铺快照。另实测未完成 HTTP 握手在正常退出后可用 TCP RST 表示关闭，WS 脚本同样接受 EOF/RST，仍要求进程 exit 0，超时或未关闭继续失败。修复的同快照 Linux 结果待实际完成补记。
