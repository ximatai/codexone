# 账号池路由与持久准入

本变更的 v4 为 dispatch 契约引入版本；当前由[账号观测 v5](../account-observability/proposal.md)继承并扩展，现行迁移/备份规则见[运行规范](../../specs/operations.md)。

## 目标与依据

接续已复审的账号授权/管理，推进 M3 的 I02/I04/I05/I08/I13 与 U02/U06/U07。先建立托管账号的持久准入屏障，再接传输选择/身份固定、健康与额度；不把一个纯内存轮询器当作账号池验收。

托管 dispatch 绑定账号 namespace/id、管理 revision、credential version 和实际访问令牌期限；Core 从当前可信密文解密得到瞬时凭证，公开 DTO 与持久 admission 均不包含 token。开始使用前检查 ready 和模式，SQLite 准入事务与 Key 当前权限/资源治理一并复核这些条件。准备凭证后被禁用、刷新、重新授权或过期的快照不能新准入。draining 只允许已核实归属/连接固定身份的续接；新无归属请求只能选择 enabled，disabled/refreshing/requires_auth/auth_uncertain 不得派发。

为防旧二进制忽略新增托管 dispatch 契约，核心库升级到 v4；表结构沿用 v3，admission JSON 新增可选账号快照。旧 admission 保持可读，匹配已托管账号的执行必须有快照，不能省略字段绕过。v1/v2/v3 均须离线显式迁移、实例锁与私有一致性 pre-v4 备份，普通启动拒绝；旧版不得打开 v4。迁移不提前恢复执行/刷新 intent，恢复仍在普通启动事务中完成。

后续路由先求 principal 对象归属与连接约束的交集，再检查账号/能力/暴露；未知或歧义引用不得向池试探，WS 一旦选定身份不得跨 lane/重试更换。无归属的新执行按最少在途和稳定打散排序，原子取得唯一执行租约；任何持久 intent 后的失败不进入其他账号循环。账号健康不能因客户端取消、本地容量/Key 限额下降。过期凭证只经既有有界共享刷新 owner 更新，uncertain 不自动重用。

## 切片与验收

1. Core 瞬时 dispatch 凭证/快照与 SQLite v4 原子屏障；真实库验证禁用/刷新/重授权/过期竞争、draining 边界、旧数据兼容与 v3 升级/备份/回滚。
2. 有界账号选择、共享刷新衔接、HTTP/SSE/压缩及 WS 固定身份；真实合成 socket 验证跨主体/账号拒绝、并发与无重放、关闭/重启责任。
3. 健康/cooldown、可信订阅额度/重置观测与按 Key 查询，管理解释和实际浏览器操作。

按可验收业务闭环集中 review 与阶段完整验证，阶段内由主 Agent 亲自实现并做定向回归；状态只记实际通过的入口。生产仍固定可信端点，测试只用显式合成工厂，不调用真实账号或消耗额度；M2 Desktop 和恢复缺口继续保留。

账号选择接入前的边界校准：凭证 namespace 既有上限为 512 UTF-8 字节，而旧单身份持久准入/归属查询把它混在普通 256 字节标识里。托管账号延续已定的 512 上限，其他 ID 保持原限制；需通过最长 namespace 的真实准入/绑定/跨主体归属回归，避免合法凭证已保存却不能使用。

## 原子选择用例切片

Core 持有当前 Key 策略与有界候选凭证；先获取既有 finalizer ticket，再准备最多 64 个账号，防并行请求积累无容量 owner 的明文快照。16 个 ticket 的最坏凭证原文包络约 32 MiB，不引入新后台任务/全局串行网络 actor。首次无归属仅取 enabled/ready，引用与连接约束先求唯一 managed identity；SQL 原子准入再次求交并复核，新增同名绑定不能制造检查/使用竞态。引用可跨多个候选消歧，但不能跨主体或向提供者试探。

同一 DB 事务根据当前身份 active 数与请求 seed 的稳定打散排序，先排除身份暴露/预算容量和失效快照，再取得单一执行 intent；Key/全局/主体拒绝不被误当某账号故障。任何已成功准入后的调用失败仅交 finalizer，绝不换账号重放。当前用例先验收有效 access 的路径；过期/正在刷新与 Runtime 单飞衔接、实际 HTTP/WS 另接，不把纯库测试当网络验收。模型范围先使用管理配置的明确共同白名单与 Key 范围交集，不从任意上游拒绝扩大能力。

## 共享刷新的路由衔接

有效 access 候选存在时直接选择，不主动刷新全部账号；仅无可用 work 时，按账号 ID 的稳定顺序选择一个过期/正在刷新的合格身份，调用同一有界刷新 owner 并重新准备。带归属只等该身份。单次请求至多加入或发起一次刷新，失败不切换其他账号轮流消耗刷新令牌；仍无生成 intent。请求取消仅移除该等待者，finalizer ticket 同时释放，已接受刷新由既有 owner 完成。

管理刷新维持原 revision CAS。路由使用内部观察的 credential version 加入同一账号的现存工作，允许 begin intent 已使管理 revision 增加后仍安全加入；已知不同 credential version 拒绝。管理先入队尚未公布工作版本时，仅完全相同原 revision 可加入，否则返回冲突，不凭未知 intent 创建新刷新。ready 才可新建工作，refreshing 且没有本进程 owner 不重放；重启仍按 uncertain 恢复。账号模式变化/禁用、Key 撤销及额度在刷新后的最终准入继续复核。

## 订阅数据凭证装配

把持久账号 work 接到数据传输之前，适配器须重新核对已保存可信 ID 基线、当前 access 的 subject/account、固定 namespace 与实际访问期限；只从该可信范围产生 Bearer 和 chatgpt-account-id，不接受下游同名头或组织/项目覆盖。此解析只消费 Core 从可信密文准备的 work，不扩展成 JWT 导入或通用签名验证器。认证头仅为瞬时值，description/debugDescription 脱敏，不编码或持久化。

生产目标固定为 chatgpt.com/backend-api/codex，必须匹配生产认证 realm；显式合成工厂仅允许 loopback 端口且须来自合成 realm，禁止将生产命名空间/凭证转发到测试地址。两类目标均无地址运行时覆盖。协议头依据 OpenAI Codex 公共实现的 [bearer auth provider](https://github.com/openai/codex/blob/main/codex-rs/model-provider/src/bearer_auth_provider.rs) 核实；该实现是兼容证据，不承诺内部订阅协议长期稳定。

## HTTP 数据面切片

复用已验收的 Responses JSON/SSE/压缩解析与绑定/证据流程，把单身份和订阅池作为两种实际授权来源。抽取共享模型/profile/传输配置，旧单身份 JSON 与行为保持兼容；新的私有池配置仅包含明确模型/profile、预留和执行期限，不含上游地址、账号、token、组织/项目或任意头。生产池只接受托管 Key，要求数据目录、管理凭证与独立主密钥，和旧单身份配置互斥。提供显式合成工厂给测试，不提供生产地址覆盖。

每次请求重新验证 Key，Core 池用例在持久 intent 后给出唯一账号，适配器将其可信认证值用于一次 HTTP POST。客户端头不会透传；AHC 禁止重定向、连接建立重试、代理继承和解压，HTTP/1 且每连接一次使用。JSON、SSE、压缩和用量/归属处理复用同一代码；错误不重发、不切账号，部分/终态证据仍由 finalizer 收尾。此切片池只启用 HTTP，明确拒绝 native WS 升级；后续连接固定身份另验收。

真实合成 socket 验证两账号/两主体、并发、绑定与续接、管理禁用/Key撤销、刷新、未知失败不重放、JSON/SSE/压缩及取消关闭。配置检查不得建库或请求网络，未知/歧义/跨账号引用在发送前拒绝；现有单身份 HTTP/WS 脚本必须完整回归。M3 不因 HTTP 切片单独标完成。

HTTP 提交后 review 校准：目录顺序属于有效策略，只有价格摘要按 ID 排序，目录/profile 摘要保留配置顺序。readiness 须在有界本地检查中证明至少一个 enabled/ready 或本进程 refreshing 候选的密文能由当前主密钥和存储 context 打开；错误主密钥/全部损坏不能 ready。单个损坏不遮蔽其他合格账号，不改授权状态，不请求上游；合法可解密的过期 access 仍可经已就绪刷新 owner 处理。
