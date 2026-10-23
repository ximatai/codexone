# 真实订阅验证记录 · 2026-10-23

授权：用户允许建议范围内真实调用，并指定可使用旧服务或本机已有身份。只读检查旧服务healthy，有一份active且访问快照距到期超过一小时的订阅身份；未调用刷新、未输出账号或凭证。现有公开测试环境账号0、未决0，仍为合成上游。

无凭证TCP/TLS检查：测试服务器认证目标TLS校验通过，生成目标直连失败；本机两目标TLS校验通过。未发送认证或生成请求，不能把TLS通过当成真实生成通过。代码明确配置proxy:nil，旧服务则配置代理，实际根因尚需单独对照，不猜测为账号异常。

真实调用与结果将在执行后记录；本轮不以CLI/HTTP辅助探针充当实际Desktop验收。

## Clash及身份核对

用户明确服务器已安装Clash，并允许读取旧服务配置。只读检查旧服务HTTP/HTTPS代理配置，经同一代理的CONNECT与TLS主机名/证书校验，认证和生成两官方目标均通过。用现有访问凭证在旧服务进程外的独立只读诊断中执行额度GET，返回200、包含rate_limit、allowed=true、limit_reached=false；未调用刷新、未修改旧账号或服务。

## 首轮实际提供者请求（未通过）

macOS arm64，沿用56600c0产品代码；临时loopback网关采用M2静态访问快照，独立托管Key限制4次请求/在途1/未决1，单一模型。实际向固定官方订阅目标发送一次短文本SSE请求，显式max_output_tokens=128；返回网关502/upstream_rejected。原隔离账本观测为generation/unknown、outcome.kind=failed、未决1，无可信usage；按未知暴露处理，未记零消耗，未进行第二轮或自动重试。

访问快照和管理凭证已清除，旧服务/原公开合成入口、配置和数据未变。首轮私有探针使用自动临时目录，导致结束时隔离SQLite也被清理，这是探针设计缺陷；保留了不含账号/正文/凭证的调用结果记录，但缺原始attempt ID及SQLite，不宣称可完整重放核对或恢复验收。后续私有探针已改为保留独立账本与安全报告、仅清除凭证；修改尚未通过新一轮实际调用验证，也不因此消除本次未知责任。

只读旧实现明确将max_output_tokens列为订阅上游不支持的字段并移除；本轮请求携带此字段，新网关原样转发。它是已发现的契约风险，不能因未保存原上游状态/分类就认定为本次唯一根因；不能静默剥离硬输出上限制造成功。当前产品代码三个HTTP客户端配置proxy:nil，原生WS直连，故尚未支持服务器已有Clash路径。

本次只证明已有身份/代理的只读检查可用，以及一次实际生成请求未通过。下一步先补齐有界出网配置、固定拒绝诊断和持续保留账本的探针，再继续小范围真实生成与Desktop；未开始代理业务代码修改，不以本机结果替代服务器或账号池验收。

## 出网与失败诊断实现 · 2026-10-23

新增显式可信HTTP代理配置，覆盖生成HTTP、WS CONNECT、认证/刷新和额度GET；目标TLS验证、无重定向/自动重试、原owner/期限保持，代理失败不回退直连。空/未设置直连，拒绝userinfo/其他scheme/非根路径等；安装受控manifest显式传入，不自动接管宿主代理环境。网关公开错误附有效服务端UUID，内部仅新增白名单码/HTTP整数状态及固定不支持输出上限分类，最多读取4 KiB错误用于固定分类而不记录正文，不静默删字段。

macOS定向6项Swift诊断/代理配置测试通过。实际代理socket覆盖HTTP/WS成功、407/断连/超时/SIGTERM、无直连回退、CONNECT无订阅/下游凭证，退出后SQLite中的unknown仍可读取；目标错误证书被拒绝且无应用数据/Bearer送达。合成OAuth code交换、refresh及额度GET各自经过代理并通过，凭证不进日志或SQLite明文。

开发中的测试失败不计通过：HTTP上游配置不开放下游WS，取消探针改用HTTP原始连接；基础fixture主动拒绝任何Authorization，已增加明确匹配合成上游Bearer的接收校验后复用协议fixture；一次验证与二进制链接重叠导致子进程退出，稳定构建完成后完整定向套件重新通过。未读取真实请求/凭证到仓库或改旧服务，真实新调用尚未执行；完整后端、Linux与两轮结果在完成后补记。

2026-10-23，主 Agent 自查后 macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend` exit 0：201项Swift测试、格式/依赖方向/文档和全部后端进程/socket/恢复脚本通过，包含新增显式代理套件。新增认证/refresh/额度合成组装恰好3次CONNECT，无直连旁路；错误目标证书在HTTP及WSS均未收到应用凭证。此时Linux候选仍在构建，真实两轮未运行，不计通过。

Linux amd64 / Swift 6.4.1首轮verification未通过：新增代理WS成功组收到终态后立刻读账，未等待受监督finalizer持久化；断言看见未settled状态。依据ExecutionCoordinator终态观察/异步handoff契约，测试改为3秒内收敛、准确2/4笔、无重启/新派发，并检查正常停服后全部settled、故障组仍unknown；不改产品结算语义。修改后macOS整个代理套件及Linux整个verification target均exit 0，失败尝试不计通过。

Linux剥离release程序实际通过HTTP/SSE/原生WS/Lite/工具诊断/合成fixture/Images，以及快照、主密钥、存储压力和迁移切回socket/进程验证；新增HTTP/WS代理正负、目标TLS、OAuth/refresh/额度组装通过，均无外网。运行镜像实际OCI/Compose安装检查exit 0，覆盖私有初始化、非root/只读、管理SPA/Key持久化、锁、旧库备份迁移和优雅重启。Linux此次不是完整Swift测试全集或真实Desktop。程序未改动后仅重标源码revision，不重复同一程序安装检查；打包会逐字节比较verification和runtime程序摘要，之后才进行真实调用。

## 服务器真实链路首轮 · 2026-10-23（未通过）

候选源码75ee891，Linux程序SHA-256 `ddc3b8f8aa46a5f3e587657b8b70421b1ab1c117f9ffd2de6cf419b785363fac`，verification/runtime/服务器提取程序三者一致。服务器独立loopback容器首次因宿主不支持CPU CFS配额被Docker拒绝，实际生成0次；保留失败预检记录，只去掉该测试容器CPU配额，内存/进程数/单并发与调用上限保持，未改宿主或旧服务。

随后经既有Clash、静态access快照发出1次真实短文本SSE请求（无max_output_tokens），网关502/invalid_upstream_content_type；未得到可信usage、未继续第二轮。新独立SQLite保留1笔generation/unknown、failed、usage=null；正常停服后读取并核对摘要，已另存私有本地副本。账本SHA-256 `29e8e825cf5c6fa5b63caf861fed22051a9a6a01e8b893d2f49da72dd881c599`；访问快照/管理秘密均清除，日志无凭证，旧服务healthy、运行身份/配置未变，原合成入口前后ready。此笔unknown与此前缺SQLite的1笔未知分别保留，不按零消耗处理，不被后续成功抵销。

尚未记录原响应媒体类型/正文，不能将此错误猜成HTML、缺头或账号异常。新增无模型、无正文的无效POST协议对照，经同一代理返回400/application-json；基础头与有限账号/客户端头两组相同，均非生成请求，未刷新凭证。正在用网关相同HTTP实现进一步复核，尚未宣称真实两轮通过。

## 缺失流媒体兼容修正

核对[OpenClaw同类问题的原始复现与维护者关闭结论](https://github.com/openclaw/openclaw/issues/90083)，发现固定订阅接口可在200/合法SSE时省略Content-Type；不据此外推本次未保存的原响应。限定缺失或真正空值进入原有SSE验证，非空精确匹配媒体essence；JSON/HTML/相似前缀及只有参数的畸形值拒绝。缺头只增加每进程一次的固定元数据观察，媒体拒绝增加固定JSON/HTML/other及200，不记录任意响应头/正文。

macOS arm64完整后端exit 0，201项Swift与全部脚本通过。最后收紧“仅参数、空essence”的非空媒体边界时一次开发编译漏改声明失败，已修正；稳定构建及整个代理套件再次exit 0，覆盖缺头两轮/空头/大小写参数成功、JSON/HTML/相似前缀/空essence拒绝，以及无头HTML/JSON/半截/畸形/超大事件失败。各次均核对无重放、可信结算或unknown持久化及无正文/凭证外泄。此时Linux重新构建中，尚未消耗剩余两次真实生成预算。

另一次与网关相同HTTP依赖的辅助无模型诊断，受本机Docker超时未得到结果；容器已核对回收、SSH转发已关闭、访问快照独立清除，不计验证通过或新增生成。前面的两组Python无模型400/JSON检查不能代替该实现验证。
