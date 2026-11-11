# 验证与完成条件

定义构建和分层验证所需的证据、命令与适用范围。

## 文档检查定义

```sh
python3 scripts/check_docs.py
```

检查稳定文档入口、本地文件链接及变更任务结构，不锁定业务目录或某个活动提案名。排除依赖/构建产物，不遍历 node_modules/.build。不检查 Markdown anchor、远端 URL、协议语义或代码。通过只代表基础文档结构有效。

## 按业务风险选择验证

变更负责人选择验证链路，并对选择和结果负责。判断时考虑失败影响、是否容易发现、能否恢复，以及已有 CI 的覆盖。先选能直接证明关键行为的检查，优先复用现有用例、自动 CI 和手工验收。评审有疑问时，指出具体的风险和缺少的证据。

- 文案、样式或可逆的界面改动，可用静态检查或浏览器定向验收。布局、滚动或操作可达性受影响时，再检查窄屏。
- 涉及权限、计费、协议、数据或恢复时，优先验证受影响的入口及最可能造成损失的故障路径。例如用旧库样本验证迁移和恢复，或经真实 socket 验证受影响的断流和重试行为。
- 涉及镜像、安装或真实客户端兼容时，按影响选择对应环境验收。发布演练适用范围见[发版规则](releasing.md)。

实现测试时优先断言用户可见结果和公开契约。表单校验、模拟失败和重试通常由组件或 API 测试覆盖，浏览器留给导航、焦点、布局和跨组件交互。用可控时钟或模拟响应触发超时，用可观察的状态等待完成。样式值、动画时长和成功截图只在本次验收明确依赖它们时检查。

同类组合按不同风险选代表用例。高成本矩阵留给手动验证或 Release。用例变慢或反复超时时，先核对它覆盖的风险和其他层已有的证据。重复用例可以合并或删除，独有场景优先改成可控触发。

自动 Verify 按工作流选择基础检查，正式发版由 tag 工作流执行发布门禁。PR 或变更记录简要说明实际执行的检查、平台、结果和重要的未覆盖范围。合成检查可证明受控场景的行为，真实客户端或上游兼容结论需要对应环境的证据。

真实Desktop验收须记录实际应用/版本、设备及模型/提供者选择、受控操作的界面结果，并与服务端请求UUID/固定拒绝原因或执行账本关联。不能把同Key/相近时间的成功预热或生成当成失败界面对应请求，不能将CLI、渲染网页或另一设备配置替代真实Desktop。电脑工具不允许操作目标应用时明确记录限制，不通过其他UI接口规避；需用户协作的一次操作应在诊断准备后进行，不要求无证据连续重试。

线上验收复用同一枚长期专用测试 Key，并按测试范围限制可用模型、每日 Token 上限和并发。平时保持停用，测试开始前启用，测试结束后立即停用并确认状态。测试失败或中断也须执行停用。自动化在清理路径中完成停用，验收记录只保留请求 UUID 和必要的结果，不记录 Key 原值或认证头。

## 本地定向验证顺序

开始时按改动范围集中查阅实现、现有用例和部署约束。可以独立运行的检查合并发起。涉及 SQLite schema 时，同一轮定位迁移入口、快照兼容、部署清单和历史夹具。

实现具备运行条件后，先启动最可能暴露返工的定向检查，同时继续独立的开发工作。与同一构建产物有依赖的检查等构建完成后启动。集中收集结果，代码发生相关改动、检查失败或还有具体覆盖缺口时，再运行对应检查。合并前完成受影响能力的验收。

复盘迭代耗时时，从现有日志取开工、首轮定向检查启动、命令完成和工具结果可读时间。分别比较命令实际运行时间与结果返回的间隔，并行区间按墙钟时间去重。把记录留在本次变更的工作记录里，使用相近范围的迭代比较。

当前 SQLite schema 版本由 `codexone --schema-version` 输出。该命令无需配置，不访问数据库。镜像清单使用构建出的二进制输出，安装验证独立读取实际库的 `PRAGMA user_version` 核对清单。历史迁移夹具保留其原始版本号。

## 测试框架与入口职责

`verify_protocol.py` 与 `verify_websocket.py` 的 binding 故障注入使用 SQLite `RAISE(ABORT)`：插入回滚，但适配器将错误映射为核心存储故障并锁住准入。关键最终化仍可尝试提交，StorageMonitor 下轮传播故障，ServiceGroup 取消服务并关闭 listener；这符合 [O09/O12](../reference/specs/operations.md)、[I20](../reference/specs/identity.md) 和 [E03/E05](../reference/specs/execution-lifecycle.md)。故障后的 ready=503 只在关闭前短暂可见，不能将它作为必须成功建立的新连接。脚本等待非零退出，检查持久状态、ID 未暴露和端口释放；WS 另验证重启不重放 unknown。正常 SIGTERM 与半截握手关闭在故障注入之前独立验收。容量/水位降级的存活及 503 由存储压力检查覆盖，不与核心故障混用。

两脚本失败时在清理前打印 `process.poll()`、保留的启动输出及当前可读的 stdout/stderr（合并流，尾部最多 64 KiB），不等待运行中进程的 EOF；临时目录、二进制路径和已知合成秘密会替换。该诊断只用于脚本自己创建的合成进程，不采集部署日志或真实账号数据。`verify_gateway_diagnostics.py` 覆盖启动失败、非零退出、无 EOF 的活进程、输出上限与脱敏。

Swift Testing 按 Core/Adapters/Runtime/EndToEnd targets 分组；NIOEmbedded 测协议 handler，临时端口测实际 HTTP，进程脚本测配置、信号、部分启动失败和端口释放。前后端共用 `Tests/CodexOneAdaptersTests/Fixtures/system-status.json` 契约样例。需要验证 SQLite 或真实上游行为时，使用对应实现的入口和数据。

前端使用 Vitest + Testing Library 测状态/校验和重试，Playwright 测真实浏览器的桌面/移动流程；浏览器测试可拦截合成 API。`scripts/verify.sh` 组合边界、格式、构建、各层测试；支持只验证后端或前端；浏览器项目区分配套 Chromium 与本机 Chrome，新建临时上下文，避免依赖用户浏览数据。设置 `PW_TEST_CONNECT_WS_ENDPOINT` 时 Playwright 与 `web/scripts` 的实际界面脚本改为连接外部浏览器（`web/scripts/browser-server.mjs` 启动），供无法启动 Chrome 的 macOS 沙箱贡献者使用。依赖安装、浏览器准备和运行命令见贡献指南，CI 使用锁文件，测试默认不读账号/外部上游。

默认客户端候选出口通过verify.sh的显式--client入口提供固定客户端路径及版本，缺少客户端或版本不符必须失败；不能以普通后端CI通过代替。脚本新建私有CODEX_HOME/空工作区、loopback合成身份及实际trial_provider序列化，分别验证默认内置目录/显式受信目录、文本三轮/工具往返/压缩续接与三种传输；断言客户端完成、实际传输无回退、上游次数与持久账本。默认路径通过--require-lite要求实际覆盖Lite工具包（可在WS预热中出现）。仅未支持web_search显式关闭，压缩场景显式降低阈值；不读取个人登录或修改个人配置。这是固定CLI合成兼容证据，不能替代Desktop UI或真实提供者。

另可显式选择 `--transport fallback --scenario tools`，在客户端开启 WS、合成网关仅提供 HTTP 的条件下核对同一工具轮的两次生成均走 HTTP，并核对真实写入次数及结算。另有 `--transport session-fallback --catalog default --scenario text`。本地测试入口对 WS 握手返回 426，固定客户端通过同一个 App Server 线程发三轮，断言首次 HTTP 成功后没有额外 WS 握手，并逐轮核对发往上游的有序用户和助手历史、客户端收到的助手回复、上游调用次数和每笔结算的用量。两项均不验证跨进程恢复后的传输策略。

固定版本 CLI 的原生 WS 断线和中断验收使用 `scripts/verify_client_continuity.py`，分别传入 `--scenario prewarm-drop` 和 `--scenario late-interrupt`，两项都需要 `--binary`、`--codex` 和 `--expected-version`。第一项在预热后丢弃首个增量请求的上游连接，检查客户端在新连接重送开发者上下文、工具和用户输入，原执行保留未知。第二项通过 App Server 的 `turn/steer` 触发中断，测试中间层延迟实际客户端中断帧至原响应终态已到达，核对迟到回复、同一连接的后续响应和每笔用量。两项只使用回环合成上游。双账号后续轮 429 由 `poolNativeWebSocketRateLimitedContinuationDoesNotMoveToAnEligibleAccount` 覆盖。

同一脚本的 `incomplete-with-usage` 和 `incomplete-without-usage` 使用合成的 `response.incomplete`，核对客户端收到 `invalid_recipient`、下游帧保留未完成的工具调用、同一会话下一轮成功且失败轮未重放。有完整用量时失败轮结算，缺少用量时账本保留未知。

`scripts/verify_request_parameters.py` 检查订阅路径中的命名空间工具结果缺少 `call_id` 时的转发，覆盖 HTTP JSON、SSE 和原生 WS，逐项对比上游收到的开发者消息、工具结果及顺序，只移除客户端本地 `id`。`scripts/verify_lite.py` 检查顶层托管工具与 `additional_tools` 共存时，独立 compact 端点和流内压缩均保留工具声明的位置，续接请求完整转发返回的压缩上下文及工具声明。两项使用合成上游，实际 Desktop 插件运行及提供者执行托管工具仍需分别验收。

现有 `verify_websocket.py` 分片包含三项额外的合成协议回归：暂停读取期间的上游突发事件按序交付并结算一次；完成一轮后上游空闲断开，客户端重连并重送完整历史；同名顶层工具与命名空间工具在原生 WS、HTTP JSON 和 SSE 桥接的终态响应中保留各自的标识。暂停读取的场景不单独证明内核缓冲已耗尽。重连场景不假定旧响应 ID 一定只能在原物理连接使用，也不代替真实 CLI 或提供者验收。

## 真实网关与浏览器 CI

GitHub Actions 的 Verify 和 Release 通过 `CODEXONE_CI_APT_MIRROR` 使用 Kernel.org 的 Ubuntu HTTPS 镜像，APT 继续验证 Ubuntu 签名。相关容器构建仅在安装依赖时使用该镜像，默认的本地构建沿用基础镜像软件源。

前端完整浏览器集合中的 `admin-live-real` 会启动实际网关，先构建 `.build/debug/codexone`。CI 的普通 `frontend` 通过 `CODEXONE_WEB_STUBS_ONLY=1` 只跑隔离的合成 API 浏览器场景；独立 `frontend-live` 使用固定 Playwright 镜像及同次 `backend-build` 产物运行真实网关/浏览器测试。PR 只有选中后端检查才构建网关并要求该任务成功。纯前端 PR 只跑合成浏览器，接受网关与 SPA 的联调回归在合并到 main 后才发现。需要合并前验收真实栈时，可手动运行 Verify；main 推送也总是运行。

`scripts/verify_tls_proxy.py` 使用临时 CA、独立 Nginx prefix/端口及合成管理身份，实际验证管理 WSS 快照、退出登录关闭、精确 Host/Origin/路径/认证和监听面隔离。它只在临时代理删除 live upgrade 路径来验证旧模板仍可提供 HTTPS 管理，再恢复配置；分别以 30/60 秒 read idle 维持同一条连接越过窗口，响应心跳并验证双向控制帧。期间有 freshness 消息，不能声称只靠 ping 保活。`--browser` 另运行 Chrome 直连 HTTPS 的登录、实时连接、Key 创建/禁用/刷新及退出；只允许该临时证书的 SPKI，不改系统信任或绕过 Host/Origin。全部为合成接口检查，不代表已部署代理或真实提供者验收。

## 独立镜像内存测量

`scripts/measure_image_memory.py` 只运行本机已有的 CodexOne Linux amd64 镜像，不构建、不拉取镜像，不进入后端 CI 分片。先由操作者准备待测 CI 镜像，再运行（输出只含合成结果）：

```sh
python3 scripts/measure_image_memory.py --image codexone:candidate \
  --memory 768m --cpuset 0-1 --output artifacts/memory-two-cpus.json \
  --env MALLOC_ARENA_MAX=2 --env MALLOC_MMAP_THRESHOLD_=1048576 \
  --env MALLOC_TRIM_THRESHOLD_=16777216
```

输出目录须已存在。不传 `--env` 使用镜像默认值；显式 `--env MALLOC_ARENA_MAX=` 等空值会在启动进程前用 `env -u` 移除对应变量，三项都重置才能比较 glibc 原始默认。`--cpuset` 缺省使用 Docker 可用 CPU，记录 Docker VM/宿主可用核数，不把 cpuset 等同线程数。`--rounds` 默认 3，每轮 6 个 30 MiB、6 个 200 图片项的 28 MiB、3 对并行 22 MiB 请求（共 18 个/轮）；前置一次 64 KiB WS 探针，最后 20 个小请求。可设 `--rounds 6` 复测约 108 个大请求，或 `--rounds 0 --final-idle-seconds 1` 快速排查 WS。每轮默认空闲 20 秒、最终 60 秒，可参数化，不将累计空闲错标为连续 90 秒。

工具使用唯一容器/网络名，固定合成身份、宿主 loopback 假上游和仅允许固定合成目标的 CONNECT 隧道，结束后移除自己的容器/网络并关闭 socket。默认让 Docker 分配独立网段，也可用 `--subnet` 指定空闲私有网段，不重用或删除既有网络。Docker Desktop 通过 `host.docker.internal` 接入宿主隧道；Linux bridge 需用 `--host-address` 与 `--tunnel-bind` 指定可达的私有宿主地址。不要指向部署实例或真实上游。

旧工具在 Docker Desktop/Rosetta 下代理主机名的 WS 请求全部 502，隧道连接数及假上游调用数均为零；同一镜像仅改为容器内解析的 IPv4 即恢复 CONNECT/WS 200。本次 macOS 原生构建也能复现：相同仅监听 IPv4 的合成代理，用 `127.0.0.1` 为 200/一次 CONNECT/一次 WS，用 `localhost` 为 502/零 CONNECT/零上游调用。这是网关的代理主机名连接问题，不能归为假上游或 Rosetta 专属故障；准确的地址候选/连接 owner 失败机制尚未确认，本次不改网关解析、重试或回退语义。

工具默认在镜像内解析宿主 IPv4，使用数字地址连接自己的隧道，让内存测试真正走通。可用 `--proxy-resolution hostname --rounds 0 --final-idle-seconds 1` 保留原主机名通路复现故障；失败仍非零退出并保留报告。报告只记录解析模式，不存宿主地址。这是测量通路适配，不是网关修复声明。首个探针和最后小请求均须 SSE completed/DONE、200 且假上游确认为 WS；大请求须确认为 HTTP 回退，否则失败，不再将 502 混入成功内存报告。

报告记录不可变镜像 ID、限制、在线 CPU 数、allocator 覆盖与实际生效值、HTTP/WS 调用数、隧道错误及各检查点 cgroup v2 `memory.current`/`memory.peak`、anon/file 与 OOM 事件；字节单位。peak 是容器全生命周期高水位，检查点可能漏过瞬时 current 峰值；anon/file 不是 RSS，含 tmpfs 的容器开销不等同进程常驻内存。请求失败时保存已取得的检查点并返回非零。报告不得包含真实正文、凭证或私人地址。

Rosetta 和 Docker VM 仅用于合成诊断；假上游无真实延迟/生成负载，不代表真实订阅或正式容量。macOS 源码测试不验证 glibc，镜像参数的效果须用包含本次修改的 CI 镜像在原生 Linux 与目标 CPU/限额复验。该工具不能替代 O14 的完整混合流量、FD/task/队列/存储及弱宿主验收。

## 发版 CI 验证边界

Verify 的 `changes` 用 Git diff 选择 PR 检查：Markdown、docs 和 LICENSE 只跑快速检查；web 选前端；Sources、Tests、Package、scripts 和 deploy 选后端；`.devcontainer` 选开发容器检查（构建镜像，在其中编译 codexone 并做前端类型检查）；`.github`、`scripts/verify.sh` 或未知路径选全部。混合修改取并集，重命名同时检查旧/新路径。main 推送如果只涉及文档且推送前的提交已有成功的 main Verify，只跑基础检查。其他 main 推送及手动 Verify 选择全部检查。独立 `docs` 始终检查文档、架构、分片完整性和容器版本一致性，包括开发容器与 CI 的 Swift digest、Node.js 版本一致。最终 `verify` 始终运行，要求所有已选任务成功，筛选跳过算成功；可将它设为稳定的 required check。

后端在 `changes → backend-build` 后并行运行 `backend-swift-tests`、四个 `backend-scripts` 分片和 `frontend-live`，普通前端在 changes 后独立运行。build 做格式检查及一次 `swift build --build-tests`；Swift 测试任务下载同次编译的 Linux 测试运行器、资源和 Swift 动态库，串行执行 XCTest 和 Swift Testing，最终门禁要求所有选中任务成功。四个脚本分片下载同一次构建的 codexone/ExecutionProbe tar（保留执行权限，附带该构建链接的 Swift 动态库），其余脚本/合成 fixture 来自 checkout。分片在 Ubuntu runner 上执行，联调在 Playwright Noble 镜像中执行，均使用归档随附的 Swift 库和环境自带的系统库，不另装系统依赖。Swift 编译任务与 Dockerfile 固定相同的 6.4.1 digest；`.build` 缓存按容器 digest、锁文件和源码/测试散列区分，先恢复同锁文件、再恢复同工具链的增量缓存，未命中仍完整编译，Swift 测试仍是合并门禁。所有运行都读取缓存，只有 main 推送在缓存未命中时保存，避免 PR 推送占满仓库缓存额度。

常规浏览器用例验证交互、可达性和窄屏溢出。侧栏与额度趋势不固定像素、颜色或动画时间。账号详情桌面覆盖草稿保留与滚动，窄屏检查关键控件可达。文档截图单独通过 `npm --prefix web run test:docs-screenshots` 生成，常规套件仍留存失败截图和 trace。

后端分片保留全部 45 个脚本。PR 与 main 推送对其中六个脚本使用快速模式。WS 大正文保留真实 HTTP/WS 入口的路由临界点、超限拒绝、续接保护、取消和不重放验收，将多尺寸与多传输的组合、并发正文预算矩阵、详细诊断以及重复竞争验证留给完整模式。文本契约在两个上游传输上跑代表性成功、扩展、终态冲突、用量错误和响应身份场景，其余变体留给完整模式。上传截止保留 HTTP 慢上传后的首响应超时、WS 停滞与取消、图片上传停滞与持续滴流超时，完整模式覆盖逐传输组合。zstd 保留压缩阈值、415 单次回退、响应发出后不重放、取消和停滞；完整模式覆盖容量竞争、额外故障和关闭组合。响应收尾保留终态前后断开、未知结算与不重放、SSE DONE、连接复用及代表性上游连接错误。图片保留生成和编辑的 JSON/SSE、multipart、授权拒绝、用量缺失及断流结算；扩展格式、容量和完整传输组合留给完整模式。手动 Verify 与 Release 执行完整矩阵。需要在合并前覆盖完整矩阵时，可对 PR 分支手动运行 Verify。

本地完整后端入口不变；单独复现分片需先构建，可覆盖二进制目录：

```sh
CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-build
CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-scripts 1/4
CODEXONE_BACKEND_BIN_DIR=.build/debug ./scripts/verify.sh --backend-scripts 4/4 --pr
python3 scripts/backend_shards.py --check
python3 scripts/check_ci.py
```

分片清单在 `scripts/backend_shards.json`，按实测耗时分配；`verify.sh` 保留完整调用顺序，自检要求其中每个脚本恰好归属一个分片。新增后端检查时两处一起更新。

前端使用含浏览器/系统库的官方 Playwright Noble 镜像，不在每次运行时 apt/download 浏览器；镜像 tag 必须与 package-lock 中的 Playwright 版本一致，并固定 registry digest。e2e 用严格端口的 Vite preview 服务生产 dist；完整入口只构建一次，单独跑 e2e 前须 build，见[贡献指南](../../CONTRIBUTING.md)。

Dependabot 每周检查 Actions、npm、Docker 与 Swift 更新。Playwright npm 更新 PR 需维护者从 MCR 核验对应 tag 的 digest，同时更新 Verify 的镜像 tag/digest；`check_ci.py` 拦截版本偏离。Swift 更新需同时核对 Dockerfile、Verify Swift 编译容器与缓存 key；TLS harness 的 runtime pin 同步 Dockerfile runtime，Release 缓存随 Dockerfile/workflow 的组合 hash 失效；Actions 更新不能替代容器 pin 的维护。所有更新仍须通过相关验证。

### Node 与 Actions 工具链约定

前端开发、Verify 的 `setup-node`、开发容器和发行 Dockerfile 的 web 构建阶段统一固定 Node.js 26.13.0 LTS；`web/.nvmrc` 同步，`engines.node` 为 `>=26.13.0`，Node 类型定义使用 26.x。不继续承诺 Node 22/24 开发兼容，避免类型允许调用未验证运行时的 API。开发容器按 x64/arm64 分别固定官方 [SHASUMS256.txt](https://nodejs.org/dist/v26.13.0/SHASUMS256.txt) 中的 Linux `.tar.xz` 校验值；发行 Node 镜像同时固定 tag 与 registry digest。更新时须一起维护这些位置；`check_ci.py` 继续检查开发容器与 CI 的 Node 相等。Playwright 镜像及依赖保持独立的版本一致性检查。

Actions 大版本升级的输入与行为边界如下；Action 自身使用 runner 提供的 Node 24，与项目 Node 26 分开，要求 Actions Runner 至少 2.327.1，当前使用 GitHub 托管的 Ubuntu 24.04。

| Action | 上游差异与本仓库处理 |
| --- | --- |
| [checkout v7](https://github.com/actions/checkout/blob/v7.0.1/README.md) | v5 改用 Node 24；v6 将持久凭证移到 `RUNNER_TEMP` 的独立文件，默认 `persist-credentials: true` 未改，容器 Action 内认证 Git 要求 runner 2.329.0；现有显式 `false` 保留，其余沿用默认。v7 改用 ESM，并默认拒绝 `pull_request_target` / `workflow_run` 下检出 fork PR；本仓库使用 `pull_request`，不启用 `allow-unsafe-pr-checkout`。完整历史与发行 ref 选择保持原配置。 |
| [upload-artifact v7](https://github.com/actions/upload-artifact/releases/tag/v7.0.0) | v5/v6 完成 Node 24 迁移，v7 改用 ESM，新增 `archive: false` 单文件直传，此模式忽略 `name` 并用文件名命名。全部显式 `archive: true` 保留命名 ZIP 包装；`include-hidden-files: false` 明确沿用 v4.4 起的默认值。产物名称、保留天数与缺文件策略保持原配置；执行权限仍靠内部 tar 保存。隐藏文件过滤不检查 tar 内部内容，内部范围由显式打包命令控制，源码归档由 `git archive` 产生。 |
| [download-artifact v8](https://github.com/actions/download-artifact/releases/tag/v8.0.0) | v5 将单 ID（以及只匹配一个产物的 pattern）下载统一为直接写入目标目录；`name` 仍优先于 `pattern`，多产物默认分目录，`merge-multiple: true` 才合并。v6/v7 完成 Node 24 迁移；v8 改用 ESM，按 Content-Type 决定是否解压，新增 `skip-decompress`，哈希不符由警告改为失败。全部继续精确 `name` 下载并默认解压，显式 `digest-mismatch: error`；不使用 pattern、ID 或合并。 |
| [setup-node v7](https://github.com/actions/setup-node/blob/v7.1.0/README.md) | v5 改用 Node 24 并引入包管理器自动缓存，v6 限为声明 npm 的项目并删除 `always-auth`，v7 改用 ESM 并移除虚拟 `NODE_AUTH_TOKEN` 回退。保留显式 `cache: npm` 和锁文件路径，设置 `package-manager-cache: false` 关闭隐式探测（显式缓存仍生效）；未设置 registry 认证或已删除的输入，无需新增令牌。 |
| [cache restore/save v6](https://github.com/actions/cache/blob/v6.1.0/README.md) | v5 改用 Node 24，v6 改用 ESM 和新版 toolkit。主 key、按顺序的前缀恢复、`cache-hit` 只对精确命中为 true、`cache-primary-key` 输出保持兼容；未命中不失败。保留所有运行恢复、仅 main push 非精确命中保存的策略，以及 tar/zstd 前置依赖。只读缓存令牌写入被拒绝时上游警告后跳过，不以缓存成功替代构建成功。 |
| [login-action v4](https://github.com/docker/login-action/releases/tag/v4.0.0) | 改用 Node 24、ESM；现用 GHCR 的 registry/username/password 输入兼容，默认 job 结束 logout 保留。新增的多 registry 认证、scope 等可选输入不影响此单 registry 流程。 |
| [attest-build-provenance v4](https://github.com/actions/attest-build-provenance/blob/v4.2.2/action.yml) | v3 改用 Node 24 并改进 checksum 解析；v4 包装通用 `actions/attest`，支持自定义 predicate。仍只传无 tag 的镜像名及 push 输出的 digest，`push-to-registry: true`。新增默认开启的组织存储记录显式设为 `create-storage-record: false`，无需新增 `artifact-metadata: write`；现有 `contents: read`、`packages: write`、`id-token: write`、`attestations: write` 满足镜像证明与推送。 |

跨 job 产物须保持下列对应关系；ZIP 外包装由 Action 自动解压，内部 tar/gzip 由现有命令处理，现有 SHA256SUMS、image ID 与推送 digest 比对仍保留：

| 产物名 | 上传内容 | 下载位置及消费者 |
| --- | --- | --- |
| `backend-swift-tests` | `backend-swift-tests.tar.gz` | 同次构建的 Swift 测试运行器、资源与动态库，解包到 `.build/debug` |
| `backend-binaries` | `backend-binaries.tar.gz` | runner 临时目录；分片解包到 `.build/debug` |
| `optimized-backend-binaries` | 候选镜像的 codexone 与同次构建的 ExecutionProbe tar | Release 四分片的 `binaries/`，先核对 build 输出的归档 hash |
| `candidate-release-files` | `artifacts/` 下的发行说明、校验和等 | image-checks 和 verify gate 的 `artifacts/`，保留 1 天 |
| `candidate-linux-amd64-image` | `image/codexone-linux-amd64.tar.gz` | image-checks 和 verify gate 的 `image/`，保留 1 天 |
| `verified-release-files` | gate 校验后的发行说明、校验和等 | publish 的 `artifacts/`，保留 7 天 |
| `verified-linux-amd64-image` | `image/codexone-linux-amd64.tar.gz` | publish 的 `image/`，校验后 `docker load` |
| `published-release-files` | 更新镜像 digest 与校验和后的 `artifacts/` | release 的 `artifacts/`，校验后创建 Release |

本地静态检查与前端测试不能证明这些新版 Actions 的跨 job 传输、容器执行或 registry 证明兼容。Linux 镜像构建、开发容器及 Release dry-run/发版流程由维护者在 CI 验证。

### Release 验证

Release 的 tag 和手动 dry-run 共用同一图：`build → backend-scripts (1/4…4/4) + image-checks (TLS、installation) → verify gate → publish → release`。build 先检查版本/主分支历史/CHANGELOG，解析一次 revision；后续检验 job 检出这个不可变提交，不再次解析分支或标签。dry-run 允许未发布 CHANGELOG，只运行到 gate 并上传产物；不登录 registry、不推送、不创建 Release。详见[发版规则](releasing.md)。

| Job | 运行内容及制品 |
| --- | --- |
| build | `verification-export` 仅构建优化 codexone/ExecutionProbe，runtime 复用同一 backend；提取候选镜像中的 codexone，与构建输出逐字节比较；导出源码、许可、镜像及归档 hash |
| backend-scripts 四分片 | 下载优化二进制 tar，核对 build 的 hash；只构建 `verification-tools`（固定 SDK、Python/OpenSSL/SQLite，不编译产品），在 `--network none` 容器中复用 `verify.sh --backend-scripts` |
| image-checks TLS | 下载并校验候选镜像 hash/image ID；测试镜像直接复制候选二进制和 SPA，在原非 root、只读、无网络、768 MiB 约束下验证真实 Nginx TLS |
| image-checks installation | 独立下载同一镜像，以不可变 image ID 执行原 `verify_installation.py` 的 OCI/Compose 安装检查 |
| verify | `always()` gate 拒绝任一失败、取消或跳过；再次核对 build 输出的镜像归档 hash，才上传原名称的 `verified-*` 制品 |
| publish / release | publish 仅消费 gate 的 verified 制品，校验 gate 输出的同一归档 hash，加载而不重建；推送后按 digest 回拉核对 image ID，对推送 digest attestation，最后创建 Release |

四分片每次执行现有全部 34 项后端脚本，包含旧 Dockerfile verification target 的全部 18 项；`check_ci.py` 检查这层覆盖和所有分片入口，`backend_shards.py --check` 保证每项恰好归属一个分片。优化 codexone 来自候选镜像，ExecutionProbe 为同次 release 配置构建的测试程序，不进入产品镜像。传统 `docker build --target verification` 仍保留原检查供源码验收使用。Release 原本没有 Swift 单元测试/格式检查或前端完整测试，本次仍由常规 Verify 承担，不声称 Release 已增加这些证据。

安装检查覆盖非 root/只读运行、SPA/auth/Key、锁、备份迁移与重启，使用合成数据和 loopback 上游。实际旧镜像检查按需运行，见[发版规则](releasing.md#dry-run)。

成功基线 [dry-run 41308814290](https://github.com/ximatai/codexone/actions/runs/41308814290) 的验证 job 为 23分51秒：优化编译 822.4秒、probe 10秒、串行脚本 429.4秒、runtime 25秒、TLS 26秒、安装 44秒。仅把脚本拆分仍受约 14 分钟的编译限制。Release 显式采用 `BUILD_JOBS=2`（Dockerfile 的弱机器默认仍为 1，优化选项与每批 1 文件不变），能否降低到约 10 分钟及内存峰值须在 CI 测量。四分片 PR 基线 [41314784465](https://github.com/ximatai/codexone/actions/runs/41314784465) 的纯脚本约 104–159秒，可作为调度参考，不能代替优化二进制实测；新增制品传输、重复 SDK 拉取和 gate 交接也计入总耗时。

候选制品保留 1 天，过期后重试须重新运行 build；成功 gate 的 verified 制品仍保留 7 天。2026-11-01 实测：原串行发行验证约 24 分钟；冷缓存 dry-run 约 14.5 分钟（build 10.7 分钟，四分片与 TLS/安装并行约 3.5 分钟），同一 ref 热缓存约 6 分钟（build 2 分钟）；v0.26.4 tag 发布约 16 分钟，镜像 revision、registry digest 与来源证明核对通过。检查失败/取消与摘要篡改阻断 gate 由 `scripts/test_check_ci.py` 覆盖。

### 优化构建缓存与测量

Release 复用现有 SHA pin 的 `actions/cache/restore` / `save` 保存 BuildKit 的 [local cache](https://docs.docker.com/build/cache/backends/local/)。使用临时 `docker-container` builder（BuildKit v0.33.1 固定 registry digest），避免依赖 runner 默认 Docker driver 是否开启 containerd image store；两个顺序构建共享同一 builder，结束或失败均清理。优化二进制用 scratch `verification-export` 直接导出，不把 SDK 镜像作为验证制品上传；runtime 单独 `--load`，发布来源证明仍只在 publish 对推送 digest 生成。

缓存 key 为 runner OS、独立 `release-buildkit-v1` 命名空间、`deploy/Dockerfile` 与 Release workflow 的组合 hash（包含 Swift/Node/runtime/BuildKit pins、构建命令与参数）和解析后的源码 revision；前缀只回退相同 Dockerfile/workflow。BuildKit 继续按 COPY 输入、命令和 build args 匹配层，不能因为 Actions 前缀命中而跳过源码失效；参见[缓存失效规则](https://docs.docker.com/build/cache/invalidation/)。不复用 PR 的 debug `.build`，不导出 SwiftPM 可写 cache mount。许可证与 codexone 必须在同一 RUN 从构建结果导出，否则层命中后空 mount 会丢失许可证；probe 依赖也可从空 mount 重建。

只导出 `verification-export` 和 runtime 两张构建图，绝不构建或缓存 `verification` 的测试 RUN 层，也不缓存分片/TLS/安装结果。即使所有编译层命中，本次四分片、TLS、安装及 gate 仍完整执行；命中不成为发布条件。缓存仍在 GitHub Actions 的分支/tag 访问边界内，仅受信 tag push 或手动 Release 可以写入该命名空间；不扩大 PR 缓存权限，不使用 registry 凭证构建。SHA256SUMS 不能证明缓存未被污染，来源证明也不表示无缓存、可复现编译或真实提供者兼容；缓存输出必须经过同一次完整验证。

优化输出与 runtime 分别导出 `mode=max` 图；只有非精确命中才保存新 key，保存前用当前图替换恢复目录，避免 local cache 旧 blob 不断堆积。缓存缺失按冷构建执行，导出失败不跳过验证，精确命中免去重复导出/上传。缓存可能占用较大配额并与其他 CI 缓存竞争；源码改变仍可能完整重编译，不能把重复 dry-run 的热命中时间当作每版发行保证。缓存也会保留 apt 层；需要刷新系统包时关闭缓存或提升 key 中的 `v1` 代数，再执行完整验证。

手动 dry-run 的 `build_cache` 默认开启，关闭时既不恢复也不导出/保存缓存，便于同一 revision 比较；tag 流程默认使用缓存。[GitHub 缓存访问范围](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows#restrictions-for-accessing-a-cache) 仍适用：在 main 上运行的 dry-run 可为 tag 提供热缓存，tag 自身写入的缓存不会自动变成以后新 tag 的可见缓存。维护者应分别记录未命中、同源码精确命中、源码变化后前缀命中的耗时，不能只看 `cache-hit` 判断编译是否实际复用。

预计关键路径为“构建 + 最长验证分片 + 制品/gate 交接”：两并发冷构建以约 10–13 分钟为待测目标，同源码完整层命中预计约 4–7 分钟；这是依据旧编译时间和 PR 分片时间的估算，尚无本分支 Linux 实测，源码变化、编译串行段、内存压力、网络和并发排队可能使结果更慢。缓存开销若抵消收益，可用 `build_cache=false` 比较；编译内存不足则将 Release 的两处 `BUILD_JOBS=2` 同步改回 1。回退这些优化不能移除 gate 或任何验证。

工作流/版本政策修改的本地检查：

```sh
python3 scripts/test_prepare_release.py
python3 scripts/test_check_ci.py
python3 scripts/check_ci.py
python3 scripts/prepare_release.py --dry-run --output-dir artifacts/release-policy
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7
python3 scripts/check_docs.py
```

这组检查验证 tag 格式、CHANGELOG 段落/预发布、真实本地 Git 祖先关系、分片覆盖、制品交接及工作流语法；gate 回归执行全部 64 种成功/失败/取消/跳过组合；构建 shell 通过 Docker 记录桩检查关闭/未命中/前缀/精确命中的缓存参数和失败清理，不运行镜像构建；三个镜像交接点执行合成归档篡改拒绝检查，不构建 Linux 镜像。源代码/安装包/许可归档与校验和的交付、推送后 digest/image ID 比对及来源证明只有实际运行 Release CI 后才有证据。未经明确授权，不运行真实订阅或部署验收。

## 首版替代验收记录要求

按 P11/P12、U10、C11、O13/O14 和 [项目范围](../../STATUS.md) 制作每次发行的验收矩阵，注明客户端/版本、模型/参数、端点/别名、传输/上游路径、用例与预期、实际结果及未覆盖项。合成失败测试与明确授权的真实 Desktop 流程分别报告；预热不是定时付费唤醒，图片编辑不是通用文件服务。旧服务 HTTP 200 或历史日志只能帮助确定基线，不能证明新实现结果等价。

额度验收覆盖主/次窗口、重置、观测失败/陈旧；统计验证跨 Key 隔离、时间边界、完整度、迟到更新及错误筛选。恢复验收逐项给出已知/未知执行、已有输出读取及客户端动作；不自动重执行是约束，不能据此省略实际兼容比较。

迁移演练使用独立数据目录与测试反代，验证账号身份、Key 保留/换发、域名/配置变化、存量会话和切回旧服务后的数据/凭证处理；不把首次安装成功视为迁移通过。容量验收记录参考宿主及共存负载、限制、持续时间、并发/大小包络与资源峰值/回稳，具体门槛见 O14；用户服务器上的真实切换必须另经授权。

## 相关文档

[文档导航](../README.md)
