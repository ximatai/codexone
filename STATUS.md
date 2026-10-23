# 当前状态

更新时间：2026-10-23（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

M0、M1 已完成本机验收与提交后 review/修复。M2 保留 Desktop 界面验收和恢复契约缺口；按用户授权先推进不依赖它们的 M3。M3 与 M4 的代码、集中 review 和本地合成环境阶段出口已完成。M4 的 Desktop 图片操作与真实订阅兼容仍未验收，完整里程碑不标完成。M5 已复核恢复读取契约，证据仍不足，保持未完成；按用户授权推进独立 M6，当前 v8 候选安装升级/兼容回退和合成迁移切回、真实本地 TLS 反代/HTTPS 管理，以及安全快照恢复/审计基线、主密钥多版本维护及低磁盘保护/必要运行观测闭环已完成本机实现与验收；当前混合容量包络已完成本机样本，完整 O14 仍保留；本轮跨平台出口证据见下，M6 整体仍未完成。

- M1：SQLite v1 空库迁移、实例锁、WAL/FULL、三层准入/持久 intent、对象归属屏障、累计证据幂等结算及重启 unknown 恢复；有界 DB 命令与 Runtime finalizer。M1 使用合成身份；M2 的协议实现和 M3 的账号/权限/观测进度见下方，Desktop 与恢复缺口继续保留。

- 核心骨架可编译运行：Core / Adapters / Runtime / 入口四个 Swift targets，依赖方向由检查脚本约束；Swift 6.4 严格并发，锁定 Package.resolved。
- NIO 数据健康入口、Vapor 管理健康 API、配置校验和 ServiceLifecycle 信号/子服务监督。默认仅 loopback；执行未配置时 readiness 为 503，生成请求明确拒绝。
- React19/TS7/Vite8 管理工作区，Mantine9/Router8、共享会话owner，独立密钥治理与用量路由；Query5/Zod4只读用量与表单试点，Oxlint/Prettier、Vitest/Testing Library 与 Playwright。Node 22.23.0，npm lock 固定依赖。
- 本地分支 `codex/account-governance`；未关联远程/推送；本轮按用户明确授权新增独立合成旁路部署，旧服务/旧项目保持原样。完成的提案在归纳后回收，过程可由 Git 追溯。

## 运行与检查

后端（默认数据端口 18080，管理 18081）：

```sh
swift run codexone --check-config
swift run codexone
```

受控单身份配置与合成验证见[单身份配置](docs/development/single-identity.md)。

环境变量 `CODEXONE_DATA_PORT` / `CODEXONE_ADMIN_PORT` 可指定端口，0 为临时端口；非零端口不得相同。无配置时也能启动健康入口，但不能代理生成。

订阅池 HTTP 使用 `CODEXONE_ACCOUNT_POOL_CONFIG` 私有模型/profile 配置，并要求管理凭证、账号主密钥和数据目录；与旧单身份配置互斥，配置见[账号凭证](docs/development/account-credentials.md)。

可选 `CODEXONE_DATA_DIRECTORY` 指向绝对数据目录，可初始化/恢复核心库并标记存储先决条件就绪；默认不创建持久库，配置存储也不会启用生成。Linux 构建需 `libsqlite3-dev`，macOS 使用系统 SQLite。

前端（另一个终端；固定 http://127.0.0.1:5179，开发代理指向管理默认端口18081）：

```sh
cd web
npm ci --ignore-scripts --no-audit --no-fund
npm run dev
```

使用开发代理登录时，后端启动需显式设置 `CODEXONE_ADMIN_PUBLIC_ORIGIN=http://127.0.0.1:5179`，并配置管理凭证。浏览器须使用相同的127.0.0.1地址；切换域名或端口需同时调整受信origin与代理，不能通过改写Origin或放宽CSRF绕过。生产SPA由管理入口同源提供。

仓库根目录验证：

```sh
./scripts/verify.sh --backend
./scripts/verify.sh --web --chrome
```

默认客户端合成候选出口（FIXED_CODEX显式指向所选固定版本CLI；缺少客户端或版本不符失败，不读取个人登录）：

```sh
./scripts/verify.sh --client --binary .build/debug/codexone --codex "$FIXED_CODEX" --expected-version 0.163.0-alpha.11.1 --require-lite
```

Linux amd64 候选构建、私有初始化与受控安装入口见 [Linux 安装](docs/development/linux-installation.md)。安装后用 `python3 compose-install.py <command>`，不要绕过入口使用裸 Compose；可用 `python3 scripts/verify_installation.py --image <candidate> --browser` 验证实际镜像与 Chrome 管理操作。

安全备份/恢复入口：`codexone --backup ABSOLUTE_NEW_BUNDLE`、`--restore ABSOLUTE_BUNDLE`、`--maintenance-status`、`--reconcile-restored ABSOLUTE_BASELINE_JSON`；先停服，设置独立私有数据目录及原账号主密钥。旧 v1—v7 须显式迁移至 v8；恢复后只接受托管 Key/账号池配置，须换发 Key、重新授权账号并核对缺失区间。详细步骤及边界见[快照维护](docs/development/snapshot-maintenance.md)。

主密钥维护入口：`--key-status`、`--reencrypt-credentials ABSOLUTE_NEW_BUNDLE`、`--resume-reencryption`、`--verify-backup ABSOLUTE_BUNDLE` 和 `--check-key-retirement ABSOLUTE_INVENTORY_JSON`。单 hex secret 仍兼容；新增 active/decrypt-only 私有 keyring。先停服并保留全部当前/历史解密依赖；步骤与清单边界见[主密钥维护](docs/development/master-key-maintenance.md)。

真实本地 TLS/Nginx 与 HTTPS 管理检查：`python3 scripts/verify_tls_proxy.py --binary .build/debug/codexone --browser`（需本机 Nginx/OpenSSL/Chrome 和生产 SPA）。隔离 Linux release、证书与超时边界见 [TLS 反代](docs/development/tls-proxy.md)。

实际管理 UI 的合成端到端检查（先完成后端及 web 生产构建）：

```sh
python3 scripts/verify_admin_ui.py --binary .build/debug/codexone
python3 scripts/verify_account_admin_ui.py --binary .build/debug/ExecutionProbe
python3 scripts/verify_images.py --binary .build/debug/codexone --browser
```

`--chrome` 使用本机已安装 Chrome 的全新临时上下文，不使用用户浏览数据。标准 Chromium 路径先在 web 下执行 `npx playwright install chromium --only-shell`，再执行 `./scripts/verify.sh --web`（从仓库根目录）；无参数执行全部验证。各层检查定义见 [verification](docs/development/verification.md)。

有界混合容量：`python3 scripts/verify_capacity.py --image codexone:v8-candidate --duration 600 --output artifacts/capacity-run-001`（显式长耗时、每配置600秒、新输出目录）；定向故障保护和环境前提见[容量演练](docs/development/capacity.md)。

## 最新验证与范围

2026-10-23，用户通知已发送后，所选启用Key出现warmup/generation各1条，均settled/succeeded、failure为空，全局unresolved=0；网关healthy、无OOM/重启，真实账号仍0。只读核对未读取用户正文/凭证。同期仍有unsupported_tools拒绝日志（含合成负向记录），缺主体关联，不能将它们全部归因该主请求；Desktop界面显示与辅助流程仍待确认，不把服务器执行成功标成完整Desktop通过。详见[复测记录](docs/changes/default-client-loop/verification.md)。无代码、部署或客户端配置变更，下一步先由用户确认固定合成回复显示，再定位剩余拒绝是否影响实际操作。

2026-10-23，按用户后续明确授权，既有独立合成测试服务已升级至运行候选源码363e7df及本轮fixture，保留原地址/Key/数据与旧版本回退材料。镜像`sha256:630659fe3dd6f832a29d9f9d2474353f99afb9948c5af4781653056e8e68113c`，目标实际程序SHA256 `462d4a6ffead347e79ba51a5f11c27604f6d3f872b45e79a5511040d797accf1`与已验Linux产物一致；本机实际runtime安装、受控升级/一致性备份校验及服务健康通过。首次fixture替换遗漏保留属主导致启动失败，恢复旧测试版本健康、修正属主保留后完成升级，不记为一次全绿。公网双前缀HTTPS JSON/SSE/WSS、Lite说明/预热增量、重复compact及权限负向通过；固定实际CLI默认模型通过两个HTTP入口和原生WSS三组两轮对话，20次执行全部settled（生成12/预热4/压缩4）、无额外attempt/unknown。临时诊断Key撤销，只剩所选原Key启用；真实账号0、订阅关闭、旧服务容器/镜像/启动时间和Nginx配置未变。用户可用原测试地址和原Key新建会话验证Desktop，界面验收待用户反馈，M5/O14及真实订阅仍保留。运行指纹、限定证据与私有操作边界见[升级验证](docs/changes/default-client-loop/verification.md#后续明确授权的独立合成测试服务升级)；无远程Git推送/发布。

2026-10-23，默认客户端本地合成闭环阶段出口完成（实现fc5f001，集中review修复1f9c67d）。Lite工具包严格校验、32 KiB说明边界、有限标识、原生WS同lane最近成功响应的工具身份续接及实际fixture完整终态已实现；review补齐重复compact唯一上下文和成功工具证据，复核无新增问题。固定Desktop内置CLI 0.163.0-alpha.11.1默认/显式目录、三传输文本三轮/工具往返/压缩续接18组重新通过，30次用户操作、58次上游调用全部settled，断言无传输回退/额外重试及真实成功工具结果。macOS完整197项Swift测试与全部后端脚本、133份文档及隐私/差异检查通过；Linux amd64 strip后release二进制定向协议/Lite/fixture/图片/维护/恢复/低磁盘/切回检查通过（无网络权限容器），不是Linux实际alpha CLI或Swift全集。记录、镜像/二进制指纹及未覆盖项见[闭环验证](docs/changes/default-client-loop/verification.md)。未部署/推送/真实订阅、未修改个人客户端或旧服务，线上候选不变。下一步为“可信流与失败”闭环：终态/状态/逐项一致性、HTTP SSE关联、提供者用量字段及错误分类；Desktop UI、真实订阅、M5/O14继续保留。

2026-10-23，按用户要求继续只分析、不修复部署，完成[实现与测试核查](docs/changes/gateway-reliability-audit/proposal.md)：已知默认Lite/部署夹具缺口继续阻塞；新增本机合成观察确认事件/状态矛盾、普通逐项与最终窗口不一致、HTTP SSE与WS的response关联校验差异，以及计量合法但下游total字段矛盾仍透传。首错误/failed形状分类、共享5xx健康归因、慢lane/慢上传与排队后轮换分别保留为契约/策略风险或验证缺口，不宣称已发生线上故障、权限绕过、漏账或重复工具执行。macOS arm64增量build、27项三路径行为观察（各一次上游）及六项已有定向测试完成；另仅补采集HTTP首错误的下游JSON分类，130份文档/探针语法/差异检查通过，没有以观察数冒充兼容通过。提交后集中review无需要修正的P1/P2或事实错误，并独立复现状态矛盾场景。已核实逐轮授权、失败不重放和可信用量保留的已有防线；原因、改进取舍、缺失验证及复现入口见[验证账](docs/changes/gateway-reliability-audit/verification.md)。本轮不重复全集/跨平台/真实客户端，无业务、客户端或线上配置变更；修复/部署继续暂停，真实订阅关闭。下一步先讨论默认客户端完整操作、可信流与失败、授权/故障隔离三个业务闭环的实施方案。

2026-10-23，按用户要求只读核对四个参考网关的维护活跃度，均有近期实质提交与发布；选择CLIProxyAPI与LiteLLM深入跟进。已核对关键Issue评论/关闭时间线、修复patch、指定源码及部分修复进入发布标签的祖先关系，形成[六项故障对照](docs/evidence/gateway-reliability.md)：能力目录、逐轮授权、网络/健康分类、多轮上下文、可信终态和用量责任。明确区分已发布源码、未合并/草稿、配置处理和转fork关闭；本项目已有防线不写成新发现缺陷，外部报告不代证本项目验收。本机macOS文档检查127份通过、差异空白检查通过，提交后集中review无新增P1/P2；仅文档与静态对照，未重跑产品全集或外部测试、未修改业务/客户端/服务。下一步仍先收敛默认客户端+实际夹具+多轮/失败消费的完整方案，用户恢复实施前保持修复/部署暂停，真实订阅关闭。

2026-10-23，最新用户要求“先找原因，不着急修复”：已停止后续业务代码修改与部署。新候选实际请求报unsupported_input/400（不再是unsupported_reasoning），所选原Key无attempt、unknown=0。只读源码及本机Desktop内置CLI 0.163.0-alpha.11.1隔离合成实验，确认两处独立契约缺口：默认gpt-6.1-sol走Responses-Lite，input.additional_tools不在当前允许集合；显式目录路径虽HTTP200，部署合成fixture还因usage缺total_tokens使CLI终态解析失败。仅在本机内存夹具补齐该字段后CLI exit0/turn.completed，没有修改线上服务。已有CLI验收使用synthetic-text+显式目录及不同终态夹具，未覆盖默认模型+部署夹具组合。

用户实际input类型未记录，不能把本机additional_tools复现当成已捕获真实请求结构；目前确认的是输入校验拒绝与可复现的默认客户端不兼容，第二处为进入上游后会遇到的独立夹具障碍。具体对照、单变量探针和证据边界见[只读调查](docs/changes/parallel-key-trial/verification.md#用户要求先定位不修复后的只读调查)。下一步先向用户报告原因，后续再按默认模型/Lite工具/归属与终态消费完整闭环决定方案；不继续逐字段补丁、放行未知输入或删除工具声明。当前运行候选仍为下方ff1322f，真实订阅关闭，Desktop/M5/O14继续保留。

2026-10-23，显式Codex控制字段候选阶段出口（`ff1322f`）：reasoning.context允许auto/current_turn/all_turns、null移除；stream_options支持include_usage和reasoning_summary_delivery=sequential_cutoff单独/组合，未知/错误/空选项拒绝，不改变归属或重放。依据为固定官方客户端发送结构与CodexLB保留扩展的实践，不读取用户正文；临时请求镜像未启用。主Agent亲自实现，9项定向/实际四传输最终文档及失败无派发、集中review无新增P1/P2；macOS完整189项Swift/全部后端脚本通过。Linux实际剥离程序的参数/诊断/HTTP/WS/fixture五组定向检查本次首轮全部通过，未重复无变更前端全集。

候选 `codexone:codex-context-candidate`，源码 `ff1322f71e19f86359b01c3082bd32f4b8bc76fa`，镜像ID `sha256:c5f487efefdcabb74a0a5b4f2620e709d109ea41e3e6c0a4beaf5e46aef8529b`，Linux运行程序SHA256 `8434b60656fef4b132d1d43285263d3f8e9ca1093dc1d2361676162a4c714fc5`；服务器完整归档重建及运行SHA匹配，既有私有配置/身份/管理员未变、旧服务未变healthy。公网首轮首路径HTTPS JSON/SSE通过后WSS TLS握手EOF；仅补失败/未执行项后双前缀HTTPS/SSE/WSS与三context枚举/预热、负向参数/认证/管理隔离通过。偶发TLS原因未确认，不写成一次全绿；诊断Key撤销，仅所选原Key启用，unknown=0。

该出口后用户复测仍失败，最新原因调查见上；不能将context推断为已确认的真实字段或宣称Desktop修复通过。后续方向：随后按通信复核推进失败终态/owner清理与有限订阅握手头契约，慢lane隔离先按自身结构实测，files/history/notes/async等不提前开放。真实订阅继续关闭；M5、Desktop完整能力、O14和正式切换继续保留。限定证据见[验证账](docs/changes/parallel-key-trial/verification.md)。

2026-10-23，四项已知可空控制与固定拒绝分类（`9acf3e3`）已更新合成旁路，macOS完整187项Swift/全部后端脚本及Linux逐项协议回归通过，集中review无新增P1/P2；Linux首轮WS退出断言失败，补采集重跑未复现，原因保留。公网双前缀JSON/SSE/WSS/预热/认证负向通过，诊断Key撤销，旧服务未变healthy。用户再试仍失败，现确认固定原因reasoning_members、unknown=0。进一步官方客户端源码核对发现context及summary delivery新增控制，正按明确枚举补兼容；未启用请求镜像或读取正文。旧候选和完整归档保留，真实订阅关闭，Desktop/M5仍未通过。

2026-10-23，可选reasoning兼容候选已部署（`bdb67f4`），已知effort/summary的null移除、tools缺省与显式[]保留；主Agent实现、集中review无新增P1/P2。macOS arm64完整184项Swift与全部后端脚本通过；Linux amd64实际剥离程序的五组协议/拒绝/WS/fixture定向检查通过。首轮构建随本机Docker重启以EOF中断，恢复后缓存重建成功，不将中断算通过。

候选 `codexone:reasoning-compat-candidate`，源码 `bdb67f4edd454a86f3893fd6164159b62609b965`，镜像ID `sha256:24aaa77264142d45ce875cbb181f2c8054c475826fdaed72716ba96acb81fb22`，Linux程序SHA256 `8735ced3596e8a04797d661e0078f0d5a1814e3225b19190c4bfc566a63e0838`；实际目标一致。完整镜像复用旧归档内容后按最终SHA重建，仅上传约14MiB；旧归档/服务与新侧配置/管理凭证未变。公网双前缀HTTPS JSON/SSE/WSS、null对照与预热、认证负向及撤销通过，仅所选原Key启用，账号/unknown=0，真实订阅关闭。

用户在更新后新会话仍报unsupported_reasoning/400，所选Key无attempt，Desktop文本未通过；已证明的null缺口不是全部原因。按用户扩展对照CodexLB的要求，新增[通信复核](docs/evidence/codexlb-discussions.md#2026-10-23-通信契约扩展复核)：已知text/tool可空差异实测、developer/工具顺序保持、每turn授权、首帧错误/终态清理、慢lane与订阅握手头边界。下一步集中完成四项已知可空参数及固定reasoning拒绝细分，再更新合成候选定位用户实际拒绝；不读正文/参数原值，不放宽未知成员或伪造限流码。Desktop/真实订阅、M5与完整O14继续保留。

2026-10-23，建执行前拒绝诊断闭环完成（`16082eb`）：首条WS解析失败发送标准error帧后关闭，无上游/intent；固定码白名单+服务端UUID、单调60秒最多16条日志，溢出丢弃。主Agent实现、macOS完整182项Swift/全部后端脚本、Linux同一优化程序的拒绝/协议/WS/fixture回归、集中review通过。独立新侧已更新并核对运行SHA，公网两前缀JSON/SSE/WSS及拒绝路径通过，仅所选原Key启用，旧服务未变healthy；容器日志轮转2MiB×2，真实订阅关闭。

新候选 `codexone:rejection-diagnostic-candidate`，源码 `16082eb9c84b2e2bccb7ee3daf918a92cdfd7964`，镜像ID `sha256:fb2c26d82de20d325c1643488e84a26c101e65b2ccd25fbe0e19cbfa2eb45ea0`，Linux程序SHA256 `e413efd62e3c2058d27edb8aa320342126de95e5b9e072421a6cd824f800d7eb`；旧候选保留，归档在忽略产物目录。部署使用已授权代理管理链路、校验后分段续传；无客户端SSH转发端口，具体连接信息私下保留。

此前诊断候选的真实Desktop仍失败：握手101已确认Key认证通过，当时具体码为 `unsupported_reasoning` / 400，未创建执行、unknown=0。合成公网复现可选effort/summary为null被拒、明确值正常；用户未特殊配置。该null缺口随后已修复，更新后用户实际请求仍失败，见最新记录；不能把合成对照当成已证明真实请求字段或完整Desktop兼容。见[诊断出口](docs/changes/request-rejection-diagnostics/verification.md)。

2026-10-23，用户首轮真实Desktop合成请求失败，界面显示重连5/5及通用网关错误，未计兼容通过。只读核对：新网关/fixture healthy，无OOM/重启；当时所选Key无执行/持久拒绝记录；后续临时脱敏状态诊断及具体错误码定位见最新出口，临时日志已恢复关闭。真实订阅仍关闭。

2026-10-23，独立公网HTTPS数据入口阶段出口（配置 `090d742`）：沿用数据面WS/SSE/无重试与无正文日志策略，独立公共证书和ACME webroot，管理/健康路由不公开。原Key摘要、合成上游与既有运行候选不变；原Nginx文件逐一摘要核对未变，旧服务容器/镜像未变且健康。主Agent亲自配置/验证，提交后集中review无新增P1/P2。

- macOS arm64与Linux amd64的交付模板Nginx配置检查通过；Linux隔离客户端经真实公网域名完成两条Responses路径JSON/SSE/WSS、正常证书校验、401/404/撤销Key和HTTP跳转。macOS首轮默认网络路径WSS超时，随后直连公共地址并保留域名SNI/正常信任校验完成同组检查；不据此断言首轮超时根因已解决。
- 独立证书续期使用既有Snap timer及webroot/reload hook；实际staging续期与配置检查/reload hook演练exit0。所有诊断Key已撤销，仅用户所选原Key启用、unknown=0，真实订阅关闭。临时客户端SSH隧道已停止，客户端直接使用私下提供的HTTPS地址；管理入口继续私有。
- 本次无产品程序/前端变更，不重复已通过的后端/前端全集。下一步用户以独立客户端新会话改服务地址、保留原Key进行合成联通测试；真实Desktop/订阅、M5、完整O14与正式切换仍保留。

2026-10-23，原Key复用与独立旁路试运行准备阶段出口通过（实现 `ed399bb`、受控源转换 `adf85c8`）：主Agent亲自实现，集中review及增量复核无新增P1/P2。离线私有摘要清单仅向新目标原子禁用导入，整批校验/采集时限/实例锁/逐条审计/管理员隔离；固定源schema只读转换，无法安全表达的源约束隔离，不复制账号、原Key明文、旧会话或余额。

- macOS arm64完整180项Swift及全部后端脚本、后增源转换定向回归通过；Linux amd64优化程序的源转换、导入/失败原子性/恢复态/锁、实际HTTP/WS原Key治理、合成fixture与生产pool检查通过。主Agent实际部署独立新服务，仅启用用户选定Key，其余导入Key保持禁用；诊断Key完成合成HTTP/native WS后撤销。验证材料与源私有清单一致，新侧账号/unknown为0，旧服务容器/镜像未变且健康。两侧额度/用量/撤销独立，不称正式迁移或旧余额继承。
- 已授权目标的基础合成部署、实际cgroup限制与loopback监听核对通过；CPU CFS不可用，采用共享单核CPU集合，保留硬内存/swap/PID上限，不计独占CPU或完整O14。受控SSH通道及真实Chrome打包管理页登录/导入列表/单Key状态/退出通过，安全Cookie/CSRF保留；当时通道为短时测试owner；后续公网数据入口见最新出口。
- 候选 `codexone:key-trial-candidate`，源码 `adf85c8f20cd113b7e09e38d55eb336993ee82fa`，镜像ID `sha256:1d5f847fe907e75d96f1ae5bdd439c13760dfc862db30e3d00aa5eccbcaf36bc`，Linux程序SHA256 `28e31778b6c278aefd3934d7f5f46593b70f8ed89007847c02ab56310314ed62`，与实际运行程序一致；旧候选保留，不推送或发布。具体主机/连接/安装位置与Key映射仅私下保存，后续缺失时向用户获取，不在仓库猜测连接目标。

操作见[摘要导入与旁路](docs/development/key-import.md)，限定证据见[阶段验证](docs/changes/parallel-key-trial/verification.md)。下一步用户以独立客户端/新会话切测试地址并保留原Key，主Agent再核对真实客户端协议/失败路径；当前仅固定合成回复。真实所选Key客户端请求、Desktop与订阅调用、正式切换、M5及完整O14/目标真实负载仍未验收；M2/M4/M5/M6整体继续不标完成。

2026-10-23，长任务与可信模型选择闭环阶段出口通过（实现 `15b33f5`，review修复 `bdbd427` / `0e9f20f`，Linux测试边界 `f0153fe`）：主Agent亲自实现，两位subagent集中review及复审关闭。默认总期限600秒/首响应30秒/进度60秒、HTTP/桥接/native WS/compact预算快照与取消、WS活动期间请求空闲分离；受信离线profile完整导入/覆盖/来源摘要/陈旧披露及价格权限隔离已可用。没有新增schema、在线发现或自动重放。

- macOS arm64完整后端检查逐项完成（179项Swift，修复后8项定向及相关socket回归）；Linux amd64优化程序的协议/WS/压缩/图片/生产pool导入通过。两平台HTTP、桥接WS、原生WS均完成单次125秒及首响应/进度/心跳/空delta/总期限/取消等28场景，恰好一次上游调用，正常settled、失败unknown且连接收尾。真实CLI0.163.0三传输实际采用快照指导并完成文本/工具续接；Linux显式依赖外层隔离容器，不计内层bubblewrap沙箱通过。没有前端产品改动，不重复前端全集。
- 新本地候选 `codexone:long-task-profile-candidate`，源码 `0e9f20fe7cc804eb3c596d6a58587504366d8016`，镜像ID `sha256:e062d4672233b42ec6a0e960ed244217440ccad2bcfe94a95b50448f5b1f588c`，Linux二进制SHA256 `e7382d6f28bb3f2345dafeeb162e299b8a393d5fbbd1760cd6ff6bb54288f9a5`；镜像/受测产物一致，归档重载核对通过。安装迁移/重启、默认兼容配置下不同v8同卷回退再升级与unknown保留、实际SPA Chrome操作及大屏检查通过。新增配置回退旧程序须恢复旧兼容配置；旧Desktop候选与归档保持不变。

完整证据及Linux CLI环境边界见[阶段验证](docs/changes/long-task-profiles/verification.md)，配置见[模型profile与长执行](docs/development/model-profiles.md)。产物保留在忽略目录 `artifacts/long-task-profiles/`，不推送/发布；恢复实验仍仅证明限定HTTP文本可行，不将M5标完成。下一步先讨论真实Desktop的版本、独立配置、合成上游操作矩阵和撤销方式；真实订阅调用继续关闭，M2/M4/M5/M6完整里程碑、完整O14与目标宿主等缺口继续保留。

2026-10-23，恢复关联实验阶段出口（`9b6dde7`，持久屏障修复 `c643772`，review/复审关闭）：macOS arm64与Linux amd64的真实CLI0.163.0+合成上游/实际网关通过created/文本前缀断流、完整事件读取及主动相同新turn；重试期间不新增上游调用，主动新turn新增执行，最终仅一条文本。结论为限定HTTP文本的有条件可行；fixture授权/epoch守卫不冒充产品能力，工具/图片/生产关联及M5仍保留。见[实验记录](docs/changes/recovery-correlation/verification.md)。长任务与可信模型选择的后续出口见上；真实Desktop仍先讨论操作方式，订阅调用关闭。

2026-10-23，结合CodexLB源码与GitHub讨论收敛业务取舍阶段出口（`2ba7020`，集中review无新增P1/P2，文档/架构/格式/隐私检查通过）：已选择分阶段期限/执行快照、受信版本化profile、先验证已有输出恢复、图片明确宿主/路由和分离错误健康归因；不吸纳无限重试、直接扩大256MiB入口、多节点协调和未接业务的存储迁移。依据含维护者对恢复大PR关闭未合并、拆分存储仍未接运行路径、图片路由仍缺真实错误帧的说明；没有把外部PR测试或合并状态当本项目兼容通过。见[选定取舍](docs/decisions/compatibility-policy.md)、[公开讨论依据](docs/evidence/codexlb-discussions.md)及[验证账](docs/changes/compatibility-policy/verification.md)。本轮只改决策/证据，当前120秒等限制及冻结候选 `bd38964` 不变；实现参数、规范和新候选由后续闭环交付。

当前顺序：恢复关联实验、长任务/profile及独立旁路准备已完成限定出口；用户已确认并行部署、原Key复用、单Key合成模式。下一步由用户操作独立客户端新会话，再核对实际客户端协议/失败路径；真实订阅调用未开启，生产恢复/M5、Desktop/订阅、正式切换与完整O14等缺口继续保留。

2026-10-23，CodexLB接入取舍只读核对阶段出口：提交 `e5809df` 后集中review无新增P1/P2，文档/架构/格式/隐私检查通过；主Agent对用户指定旧项目的 `6d78866` / 历史修复快照 `6689178` 逐项读取源码，未修改旧项目、读取秘密/部署配置或调用真实订阅。两份旧源码均有重复POST直接重放完整持久事件的分支，修正此前将M5过于集中于GET读取轨迹的解释；它不证明稳定操作关联、消费位置或工具安全，M5仍未完成。另确认默认单次期限、模型目录/指导来源、图片mask与stream转换、认证参数和额度覆盖差异；默认设置不代表当前线上配置。见[对照矩阵](docs/evidence/codexlb-compatibility.md)及[核对记录](docs/changes/codexlb-compatibility-audit/verification.md)。本次不改产品代码，冻结候选仍为下方 `bd38964`。

只读旧源码不代替Desktop/真实订阅/M5/O14验收；对照后新增的实验与实现已在上方记录各自限定出口。

2026-10-23，Desktop测试准备阶段出口通过：账号闭环 `ef0f8d3` / `5167d68`、图片内部封套修复 `94f6ae5`、测试守卫及预热责任核对 `96af05f` / `bd38964`。主Agent亲自实现与修复，两位subagent集中review及复审关闭，无新增P1/P2。

- 账号授权/详情/启停排空/额度健康抽屉闭环保持CAS、未知写锁和共享会话。macOS完整43项前端、最终17项定向/构建及Linux静态构建通过；最终实际Chrome合成OAuth、失败重读/会话与额度全流程通过，大屏截图已查看。
- 合法6MiB multipart转base64后被旧8MiB门限二次拒绝，现分离9MiB内部图片封套与8MiB外部上传，外部/下游预算不变。macOS arm64完整175项Swift与全部后端脚本通过；Linux amd64同一优化二进制的protocol/WebSocket/Images定向socket回归通过。
- 两平台HTTP同一TCP各33轮/125秒，WS配置另保持原生上游单连接32轮/125秒；最大6MiB四图/图+mask、4MiB输入输出工具、各越界拒绝、实际取消、无重放和unknown/预留独立核对通过。峰值RSS约101—171MiB、收尾队列归零/FD及RSS回稳；只是有界样本，不等于目标宿主、async task观测或完整O14。
- 本地冻结候选 `codexone:desktop-test-candidate`，源码 `bd3896425d7cd47f6aaea95c9a616a9e06d46731`，镜像ID `sha256:2c18e874ef3ae4f1ed653c2018c04ab8e022c95b841e79c63a79046bba9e3930`，Linux实际二进制SHA-256 `55d76ab2b80f69885ff0fc0ec87c6877171aafdb1185a24befa42a856574acd4`。安装升级、不同v8同卷兼容回退/再升级及unknown保留、实际打包SPA Chrome通过；镜像内二进制与受测产物逐字节一致。
- 忽略目录 `artifacts/desktop-test-candidate/` 包含源码/镜像、标识、限定验证矩阵、两平台报告及已验兼容v8 peer精确源码/镜像，逐项SHA256SUMS与实际归档重载核对通过。旧v8归档保留，不推送/发布；真实本地TLS证据沿用，配置未变。

证据见[测试准备](docs/changes/desktop-test-readiness/verification.md)，操作矩阵和撤销配置步骤见[Desktop准备](docs/development/desktop-preflight.md)。冻结时计划先讨论真实Desktop；后续CodexLB对照新增前置关联实验和设计项，按上方最新顺序推进，真实UI仍须先讨论版本、独立配置和操作方式；当前未修改Desktop配置或读取个人登录缓存。真实订阅调用尚未开启，Desktop/真实订阅兼容、M5恢复读取、完整O14/目标宿主、真实旧服务切换与远程CI继续保留，M2/M4/M5/M6完整里程碑不标完成。

2026-10-23，Desktop测试准备的账号管理闭环阶段出口通过（`ef0f8d3`）：账号列表→授权/重新授权→策略→额度健康详情统一组件和抽屉，保留CAS/未知写锁/共享会话、抽屉内失败重读和回调清除。macOS完整前端43项及最终17项账号相关回归、真实Chrome合成OAuth/失败链路/大屏操作与Linux amd64静态构建通过，两位subagent集中review无新增P1/P2。长连接/图片边界与候选冻结随后完成，见上方最新阶段；开始真实Desktop前讨论操作方式，真实订阅调用暂不授权。证据见[测试准备](docs/changes/desktop-test-readiness/verification.md)。

2026-10-23，前端管理工作区优化：本地阶段出口通过。实现 `4be9f5b`、编辑回归修复 `fa3b82a`、许可打包修正 `fa509c2` / `5eefe37`，集中review及复审关闭。

密钥列表→创建/编辑抽屉→独立用量路由已可操作；共享会话清除私有视图、跨导航保留未知写锁，秘密不进入URL/持久缓存/Query。保持严格CSP，移除重复登录和不必要的副标题；账号沿用业务控制逻辑并接入共享会话，全面组件迁移留待后续。较大管理资源暴露的提前关闭问题已改为等待最终flush，保留大小/期限边界。

macOS完整前端40项/3项Chrome、review后4项Key定向回归、Swift175项、真实管理API/1MiB并发慢读及断开、实际密钥/用量/账号/图片和HTTPS操作通过。Linux amd64优化程序、静态构建、真实管理API/大资源socket、新测试镜像安装迁移/持久化/重启及Chrome操作通过；未重复未改动的Linux协议全集。阶段证据见[管理工作区验证](docs/changes/admin-workspace/verification.md)。新测试候选为 `codexone:admin-workspace`，来源 `5eefe37`，现有v8归档候选未替换；账号闭环随后另已完成，见最新记录。Desktop、真实订阅、M5、O14和目标宿主缺口继续保留。

2026-10-22，M6 当前混合容量包络阶段出口通过（脚本 `5679307`，review 修复 `5e74039`）：

- macOS arm64 / Python 3.9 驱动实际 Linux amd64 优化运行镜像，两种上游各600秒；共享 aarch64 Docker VM 2 CPU/约2.84 GiB、3个共存容器，包含仿真成本。网关1 CPU/768 MiB/128 PID、swap上限0、非root/只读/独占Linux本地卷；压测器独立cgroup、仅隔离loopback。
- 多主体Key、JSON/SSE、compact、约3 MiB单图generation/edits；native WS配置另含下游WS/warmup。持续最多4在途，HTTP/native WS实际3.891/3.775请求/秒，2335/2267次提交、30/19跳过时隙，正常操作全200。24路超载各8完成、16协议前连接关闭，不冒充HTTP429。
- cgroup峰值202.5/210.9 MiB，回稳RSS74.4/75.8 MiB（冷基线约57 MiB），FD均27→43→27；队列/WAL最终归零，无重放/intent/OOM，正常退出。长报告仅证明unknown汇总各2/预留2，修复后双配置短程以独立断流主体精确核对unknown/无完整证据，其他主体全settled。
- 集中review三项P2均由主Agent修复并复审关闭：卷创建与root初始化owner/CLI超时清理、新鲜回稳DTO、断流逐主体归属。实际Engine成功后注入CLI结果丢失，容器/卷均回收；缺失/陈旧DTO和队列未清空均拒绝。文档/架构检查通过；未改Swift/前端业务代码，沿用已通过全集及实际界面证据。

命令及限制见[容量演练](docs/development/capacity.md)，详细数字与失败记录见[验证账](docs/changes/capacity-rehearsal/verification.md)。原始报告/精确脚本来源/校验信息在忽略的 `artifacts/capacity-600/`，修复后的责任回归另存 `artifacts/capacity-review-regression/`；未拼接或改写长样本。约1.6 GiB参考宿主、HTTP keepalive/长寿命多turn、全部最大图片/工具组合、async task tracing、真实订阅/Desktop、M5缓存及实际旧服务负载仍待验收，O14/M6整体不标完成。没有真实账号调用、推送或部署。

2026-10-22，M6 当前 v8 候选、安装升级/兼容回退与合成迁移切回阶段出口通过（候选源码 `890bf2c`，review 修复 `7ad7fe6`）：

- 当前 Linux amd64 优化镜像包含快照/基线、主密钥多版本与续作、低磁盘储备/观测；实际安装、v5 私有备份迁移到 v8、同卷换真实前一 v8 再升级、Key/keyring/未知责任保留通过。旧 v6 在同配置/权限的独立兼容库先启动成功，再对主 v8 库监听前拒绝且不改真相；没有降 schema 或恢复旧余额。
- 合成旧服务独立库/备份、暂停与在途 drain、原 Host/前缀、明确换 Key/剩余配额、真实新 settled/unknown、唯一审计带回新增责任并切回通过；额度耗尽在两侧都继续拒绝，无重放。真实执行库跨不同旧 v8/当前 binary 的完整 attempts/evidence/绑定及耗尽配额保持通过。fixture 不代表 CodexLB/真实账号导入或通用跨主体基线。
- 主 Agent 亲自实现与测试，两位 subagent 集中 review/主 Agent 修复/复审关闭三项 P2。Linux Swift 6.4.1 优化程序完整 15 个后端脚本集合、同 CI 的真实 TLS/Nginx 参数与非 root/只读安装检查通过；macOS arm64 Swift 6.4 本机初始化/配置与迁移回归通过。Chrome 1440 宽实际打包 SPA 登录/发 Key/清除秘密/刷新保留/登出通过，截图已查看。业务 Sources/Tests/web 未变，沿用 175 项 Swift 与前端全集，不重复。
- 忽略目录 `artifacts/linux-candidate-v8/` 归档新候选与已验兼容 peer、精确源码/实际旧构建补丁、镜像与二进制标识、限定验证矩阵及校验和；全部校验与实际重载通过。当前 binary SHA-256 `3f04ccf776657b247009e678213d28ca179ed0d95ee8ea9f1d97b3df94504ac8` 与验证程序一致；旧 v6 候选保留。首轮 Docker EOF/缺 probe 不计通过，详见验证账。

命令与边界见 [Linux 安装](docs/development/linux-installation.md)、[迁移切回](docs/development/migration-cutback.md)及[验证账](docs/changes/v8-release-transition/verification.md)。下一步容量演练；尚未证明目标弱宿主、真实旧服务可替代或 O13/O14 全部完成。Desktop、真实订阅和 M5 继续保留，无真实额度调用、推送、远程 CI 或部署。

2026-10-22，M6 低磁盘保护与必要运行观测阶段出口通过（实现 `a32cab2`，修复 `3b7ecf8`，测试出口 `751cb8c` / `6f287bd` / `b77088d`）：

- 私有实际分配 64 MiB 结算储备、128/192/256 MiB 停准入/恢复/可选工作水位及 WAL 门禁；writer 最后复核、优先保留既有绑定/结算和权限收紧，空间恢复不删除 unknown 或赠送额度。实际 SQLite FULL 仍可能停止核心，依赖已有 durable intent 恢复。
- 单 Runtime owner 监测、非阻塞 checkpoint/报表中断，有界队列等待、空间/WAL/储备、峰值 RSS 和 0—1023 FD 观测；认证 no-store 固定 API 不含路径/正文。离线备份/恢复/迁移/再加密有源目标预算与逐页复核，失败不发布目标。
- 主 Agent 亲自实现与修复，两位 subagent 集中 review/复审关闭。macOS arm64 / Swift 6.4、Linux amd64 / Swift 6.4.1 完整后端覆盖各 175 项 Swift 测试及全部后端脚本通过；首轮旧夹具/慢隐私扫描失败后只重跑相关测试，Images 时序断言补真实重启验收后仅重跑该脚本，不声明一次全集全绿。
- Linux 本机无外部网络、2 CPU/2500 MiB 容器退出 0、未 OOM；真实 384 MiB 私有 tmpfs 耗尽下既有流结算/储备释放，清理后补足回稳；离线空间拒绝、恢复途中撤空间与 pending/原备份保护通过。macOS 不填宿主卷，采用注入水位及实际文件/SQLite 故障。无前端产品变更，不重复浏览器全集。

证据、首轮失败与边界见[验证账](docs/changes/storage-pressure/verification.md)，运行契约见[存储压力](docs/development/storage-pressure.md)。未测实际掉电、目标宿主容量或更新 OCI；Desktop、真实订阅和 M5 继续保留，M6 整体未完成。全部合成资料，无真实额度调用、推送或部署。

2026-10-22，M6 主密钥多版本/可恢复再加密/旧备份依赖阶段出口通过（实现 `f2423c5`，修复 `13bfe6c`）：

- 私有有界 keyring：一个 active、最多七个 decrypt-only，保留单 hex 文件/v1 信封/AAD；新授权和刷新只写 active，旧版本按 key ID 解密，未知 key/上下文/篡改拒绝。全版本及整份紧凑 keyring 文本均执行管理员/已配置静态数据 Key 复用检查。
- 离线同实例锁、先独立完成备份、每页八个账号的 CAS/密文/检查点同事务；页内 SQLite 写失败回滚，实际页提交后 SIGKILL 留混合版本，普通服务拒绝，原 active/完整解密 keyring 显式续作并复核后完成。凭证版本、账号授权和刷新 intent 不变，未冒充提供者刷新成功。
- schema v8 防旧 v7 二进制忽略新检查点；v1—v7 显式备份迁移，已有 v7 完成 bundle 验证/显式恢复后 staging 升 v8，原源不变。实际旧 v7 可执行文件对照证明：同一合成库 v7 可启动、v8 在监听前拒绝；不证明兼容回退。
- manifest 核对实际 schema 与实际 key ID 引用集合；候选 keyring 的退役检查覆盖全部当前密文、完整声明的保留 bundle/匹配恢复目标和原始 v7/v8 备份依赖，审计仅记录 ID/摘要/非秘密引用。完整清单、外部 raw 恢复审计、未知副本和销毁事实仍由操作者负责；原始 v1—v6 暂拒绝直接退役核对，不能因此丢弃旧 key。
- 主 Agent 亲自实现和定向验证，集中 review 的维护入口复用、整文件复用及 manifest schema 三项 P2 已修复，两位 reviewer 复审关闭。macOS arm64 / Swift 6.4 完整后端脚本、Linux amd64 / Swift 6.4.1 同等完整后端检查均 exit 0：各 166 项 Swift 测试及全部后端脚本通过。Linux 本机无外部网络、2 CPU/2500 MiB、native 单并发，未 OOM；对应 `13bfe6c`，临时容器已回收。

命令和限制见[主密钥维护](docs/development/master-key-maintenance.md)，证据见[验证账](docs/changes/master-key-maintenance/verification.md)。本阶段没有前端产品改动，不重复浏览器全集。全部合成资料，无真实账号调用、额度消耗、推送、发布或用户服务部署；Desktop、真实订阅、M5、低磁盘完整保护、目标容量与新 OCI/安装/兼容回退仍保留。

2026-10-22，M6 安全快照恢复与审计基线阶段出口通过（实现 `7bd70ba`，review 修复 `704ebd5`）：

- v7 离线一致性私有 bundle，完成 manifest/摘要/来源和单主密钥依赖；仅恢复到全新目标，父目录与 restore-pending 持久屏障、受保护 staging 发布，中断拒绝普通启动。旧 v1—v6 须显式迁移，旧二进制拒绝 v7。
- 旧快照恢复持久维护态、披露快照时间/复制完成时间及核对风险区间；intent→unknown、旧绑定删除、旧 Key 验证材料失效、账号需重新授权。恢复库拒绝 legacy 静态身份，须托管 Key/账号池；新 Key 在维护/冻结期也不能生成。
- restore ID/CAS/追加审计绑定显式缺失未结数量和金额；首次核对冻结当日 UTC 窗口，跨午夜不提前放行。缺失占用跨日保留并与已知 unknown 叠加，后续修订须外部证据，不自动归零/退款。新日、新授权只授予新配额，不复活旧余额。
- 主 Agent 亲自实现和定向验证，集中 review 后修复父目录同步遗漏、跨日冻结与 legacy 虚假就绪，12 项相关回归及真实 CLI/HTTP/SIGKILL 通过，两位 reviewer 复审关闭。
- macOS arm64 / Swift 6.4 完整 `./scripts/verify.sh --backend`、Linux amd64 / Swift 6.4.1 同等完整后端检查均 exit 0：各 159 项 Swift 测试与全部后端脚本通过。Linux 为本机隔离无网络容器、2 CPU/2500 MiB、native 单并发，未 OOM；源码及测试对应 `704ebd5`，容器已回收。没有前端产品改动，不重复已通过的浏览器全集。

命令与证据见[快照维护](docs/development/snapshot-maintenance.md)和[验证账](docs/changes/safe-snapshot-restore/verification.md)。只用合成资料；未调用真实账号、消耗额度、推送或部署。不证明实际掉电、目标宿主容量或旧服务无损切换；多版本主密钥、低磁盘分级保护、兼容二进制回退演练和更新 v7 安装候选仍保留。

2026-10-22，M6 真实本地 TLS 反代/HTTPS 管理阶段出口通过：

- 交付完整数据/管理 TLS server 示例和共用 snippets；保持两类入口隔离、管理 Host/Origin 含端口，清除 forwarded 伪造，关闭生成自动重试、SSE 缓冲/gzip 与普通敏感 URI 日志。
- macOS arm64 debug / Nginx 1.31.7、Linux amd64 release / Nginx 1.24.0：真实 CA 链/主机名正反校验、两个数据前缀、JSON/逐事件 SSE、WSS 连续 turn/HTTP→WS 桥接、下游取消与超时关闭上游、unknown 保留与无重放、请求大小、半截上传、认证/CSRF/管理隔离通过。Linux 使用候选镜像 SPA，非 root/只读/无外部网络容器，release 二进制与前阶段相同；不是目标弱服务器容量证据。
- Chrome 大屏直接 HTTPS/Nginx 登录、Key 创建/关闭秘密/刷新保留、禁用持久化、登出失效通过，截图已查看；没有 relay/response fulfillment。临时进程仅接受本次叶证书 SPKI pin，链/主机名另由 socket 验证，不改系统信任；不证明公共 CA 或用户实际域名配置。
- 集中 review 完成：修复 Nginx 异常退出使后续 owner 清理被跳过的问题，立即注册各 owner、独立进程组回收 worker；macOS 文件写失败/master SIGKILL 定向回归、Linux 完整 TLS（含故障回收）通过，复审确认关闭。Swift/前端产品代码未变，不重复已通过的全集。

命令、版本、失败记录和限制见 [TLS 验证](docs/changes/local-tls-proxy/verification.md)。候选 CI 已加入 Linux TLS 检查，但尚未远程运行；没有真实账号调用、额度消耗、推送、发布或用户服务部署。

2026-10-22，M5 契约复核与独立 M6 候选安装阶段出口：

- 实际 CLI 0.163.0 隔离 EOF 探针再次证明 reconnect 产生新生成（原 unknown、新 settled）；公开 GET response/消费位置协议不足以证明目标 Codex/订阅读取可用。M5 未实现正文缓存，未改变 unknown、重试或退款语义。见[契约证据](docs/changes/recovery-contract-audit/verification.md)。
- macOS arm64：私有初始化、0700/0600、覆盖/链接/输入拒绝、实际二进制配置及秘密权限拒绝通过；Linux amd64 的 root 初始化/显式非 root 归属亦通过。受控 launcher 直接接收污染环境仍固定私有 file/env/project/image/volume，实际安装与升级均通过该入口。
- Linux amd64 / Swift 6.4.1：多阶段 OCI release 构建及无网络实际 HTTP/SSE/WS/Images 失败路径通过；运行二进制 SHA-256 `b323209f9302e4ae36a0de4732f1a016e359fb1e522fe1649cf8e929e42cd675` 与 socket 验证产物一致。工具链基底固定 digest，附源码 revision、许可证与生产依赖 notices；CI 候选工作流仅定义，未远程运行。
- 实际本地 Linux OCI/Compose：非 root/只读/能力清零、私有本地卷、配置拒绝、live/ready、SPA/session/CSRF/Key、在线实例锁、v5 普通启动拒绝、私有一致性备份/显式幂等迁移、重启数据保留、优雅退出均通过；目录读取失败和归属不符均拒绝且不改已有数据。macOS 共享 bind 的 flock 不可靠，默认 data 因此选 Linux Engine 本地卷，不能以共享盘通过冒充锁验收。
- 实际打包 SPA 的 Chrome 1440 大屏登录、发 Key、关闭一次性秘密、刷新持久与登出通过，截图已查看；隔离 curl relay 不是实际 TLS/Nginx 验收。Swift/前端产品源码未变，沿用 M4 完整测试证据，不重复全集。

集中 review 修复了宿主 Compose 覆盖导致误选安装的问题；命令、失败取舍与复审证据见[候选验证](docs/changes/linux-distribution/verification.md)。验证均为本机合成资料，没有真实账号调用、额度消耗、推送、发布或用户服务器部署。候选产物保存在忽略的 `artifacts/linux-candidate/`，包含镜像/精确源码归档、标识和 SHA256SUMS；仅为本机候选。该归档对应安装阶段提交 `3e03130`；TLS 配置与本轮恢复流程以当前源码为准。该旧安装候选是 schema v6，不含当前 v8 恢复/主密钥维护能力；保留旧证据，当前 v8 候选已另归档至 `artifacts/linux-candidate-v8/`，见最新验证。

2026-10-22，M4 本地合成阶段出口通过：

- macOS arm64 / Swift 6.4：完整后端脚本通过；最终用量/WS 关闭修复后的 152 项 Swift 测试、图片与 WS socket 回归及格式检查通过。
- Linux amd64 / Swift 6.4.1：精确代码快照 `fd3e28d` 完整后端验证通过，152 项 Swift 测试及全部脚本、exit 0、无 OOM。独立 2 CPU / 2500 MiB 本地容器，单并发 native 引擎与缓存依赖；容器已回收。不是远端 CI 或弱服务器容量证据。
- 前端完整类型/构建、35 项测试、3 项 Chrome 场景通过；实际 Chrome 管理操作验证仅图片 Key、独立视觉/生成授权、有效目录与用量呈现，大屏截图已查看。
- 集中 review 及复审关闭：48 模型读写/DTO 容量、零工具调用与失败/不完整终态结算、有效宿主能力目录、畸形模型拒绝；主 Agent 还修复回归捕获的 WS 关闭锁反转并验证。

配置与范围见[图片配置](docs/development/images.md)，命令/快照/失败记录见[图片验证](docs/changes/image-capability/verification.md)。全部是无凭证合成验证，没有真实调用、额度消耗、推送或部署。

2026-10-22，M3 本地合成环境阶段出口通过：

- macOS arm64 / Swift 6.4：完整 `./scripts/verify.sh --backend` 通过，138 个 Swift 测试函数（含参数案例），全部进程/SIGKILL/迁移/HTTP/SSE/WS/context/压缩/Key/session/账号/私有池配置脚本通过。
- Linux amd64 / Swift 6.4.1：后端快照 `195dfdd` 完整检查通过，138 个测试及全部脚本，exit 0。后续提交只改前端/浏览器测试/文档，后端 Sources、Swift Tests、Package 与 scripts 与该快照一致。独立本地容器，单并发、2 CPU/2500 MiB；默认 SwiftBuild 在受限 VM 遇等待/OOM，改用 native 引擎、有索引及每批最多 16 文件后完成。测试辅助入口改名解决 main.swift 与 @main 的 native 兼容问题。失败/中止尝试不计通过，容器已回收，编译缓存保留。这不是弱服务器容量或远端 CI 验收。
- 前端类型、生产构建和 32 项组件/API 全量测试通过；后续账号代际保护新增一项，连同原五项相关回归通过，共 33 项已验证。3 项概览 Chrome 场景分别通过；超时夹具修复后仅重跑失败项，未改产品超时。实际 Chrome 临时上下文接生产 SPA/合成 OAuth/真实 SQLite API：账号授权/策略、额度成功/失败保留/陈旧/受限标记、Key 创建/轮换/禁用及用量筛选/趋势/分页、失败重试/会话失效/迟到响应丢弃均已操作验收，大屏截图已查看。
- 集中 review：`fb70c05` 的一项 Runtime 周期扫描 capacity 连带关闭网关 P1、三项前端 P2，主 Agent 以 `195dfdd` 亲自修复并复审关闭；`998d630` 补齐 401 后迟到授权响应保护，六项组件与实际 Chrome 回归、复审通过。没有新增阻塞。

关键证据：[账号观测与用量](docs/changes/account-observability/verification.md)、[账号池](docs/changes/account-pool-routing/verification.md)、[池 WS](docs/changes/account-pool-websocket/verification.md)。证据全部使用合成上游/身份/临时数据，没有真实账号调用或额度消耗。无推送、发布或部署；未修改旧服务。

## 当前交付与下一步

M2 已实现 HTTP JSON/SSE、桥接/原生 WS、warmup/compact/v2 压缩、加密上下文与对象归属屏障、模型/profile 目录和客户端 namespace/custom 工具。此前实际 CLI 0.163.0 与 Desktop 内置 CLI 0.163.0-alpha.11 的三传输合成检查通过；CLI 不替代 Desktop 界面或已有输出恢复验收，详见[协议验证](docs/changes/single-identity-protocol/verification.md)及[恢复证据](docs/evidence/client-recovery.md)。

M3 已完成以下本地合成闭环：

- 独立管理员 session/CSRF、Key 创建/轮换/禁用/模型与五类限额，跨主体隔离、审计撤销预留；账号 AES-GCM 凭证、初次/重新授权、单飞刷新及保守重启。
- 托管账号的原子归属交集/最少在途选择、当前 Key/账号/凭证/期限/健康复核；JSON/SSE/compact、HTTP→WS 和原生 WS，所有 lane 固定连接身份，持久准入后失败不换账号重放。
- 被动固定 usage GET、独立四网络容量与有界观察 owner，失败保留额度/陈旧/窗口与重置；当前版本 401 屏障、429/5xx 模型冷却，普通扫描过载不关闭 Runtime，真实核心存储故障仍停止服务。
- v5 显式离线备份迁移（旧 v1—v4 普通启动拒绝）；执行 UTC 时间/结果、脱敏有界拒绝诊断、独立只读 WAL 查询。按 Key/时间/模型/模式/错误统计、趋势及明细，完整/部分/缺失证据与全时间未知暴露分别解释，轮换/迟到证据不重复计数。

运行与配置见[Key 治理](docs/development/key-governance.md)、[账号凭证](docs/development/account-credentials.md)。旧版本先按文档停服迁移，保留独立主密钥；不能原地降级或用恢复旧库丢弃新执行责任。

M4 已接续并完成原有修改：独立权限/图片模型映射、schema v6 离线备份迁移、Images generation/edits JSON/multipart/SSE 与 Responses 图片工具，复用 HTTP/桥接/native WS 执行、归属和用量；管理权限与统计可操作。代码与本地合成出口完成，图片与压缩组合明确拒绝。

M5：恢复读取契约仍不充分，详见[恢复证据](docs/evidence/client-recovery.md)。需要明确版本客户端的已有输出读取轨迹、消费位置、权限与工具风险，或明确采纳产品范围调整；没有据此新增私有协议或无人可用的正文库。Desktop 图片/参考图/连续主动编辑与真实订阅兼容继续保留，CLI/合成上游不能替代。

M6 已覆盖以下本机闭环：当前 v8 Linux amd64 可追溯 OCI 候选/私有初始化/受控安装升级、同卷兼容二进制回退及合成旧服务迁移切回；真实本地 TLS/Nginx 与 HTTPS 管理操作；安全快照恢复、缺失区间和审计额度基线；active/decrypt-only 多版本主密钥、先备份的分页 CAS 再加密/显式续作及旧备份依赖核对；低磁盘分级保护、结算储备与必要运行观测。当前 schema v8，旧 v7 bundle 可验证/恢复并显式升级，不兼容旧 schema 二进制原地回退，已验兼容 v8 peer 可保留同卷责任。当前混合容量及HTTP keepalive/原生WS长连接、最大参考图与工具图片有界包络已实测；任务观测和目标宿主预算仍须补齐；本地 TLS 通过不替代用户实际域名/证书部署验收。

2026-10-22 计划复盘校准：M6 剩余项同时包含实现和验收，不能理解为只需再跑测试。当前已提供安全快照 backup/restore/status/reconcile、多版本 keyring/可恢复再加密与旧备份解密依赖核对。完整清单、外部 raw 恢复审计和销毁事实仍须操作者负责，工具不能发现未知副本或证明外部审计。低磁盘分级退让/停止准入/结算预留及必要资源/WAL 观测已完成本机闭环，目标容量仍待验收。依据 O03/O04/O09/O10/O14，后续按业务闭环推进：

1. 真实本地 TLS 反代与 HTTPS 管理操作：本地阶段出口已完成，证据见上；用户实际部署的数据入口现已有上方限定证据，管理公开部署仍单独验收。
2. 可维护数据与密钥：安全快照/旧快照维护态/缺失区间与审计基线，以及主密钥多版本、备份依赖与可恢复再加密已实现。维护、兼容二进制回退与旧服务切换分别验收。
3. 低磁盘保护与必要运行观测：本地阶段出口已完成，覆盖拒绝新工作、关键收尾、WAL 与备份空间不足；不替代目标宿主容量演练。
4. 当前 v8 候选及安装/升级/兼容回退、合成迁移切回已完成本机闭环；HTTP/native WS各600秒、多Key/单图/断流和资源回稳包络已实测。HTTP keepalive/长寿命多turn和已定义最大参考图/工具图片边界随后通过；仍须补async任务观测、其余图片格式/帧组合，并明确约1.6 GiB参考宿主/共存服务的可解释预算；现有768 MiB容器限额不代证宿主。M5缓存未实现，完整O14仍保留。
5. 补齐 Desktop/真实订阅的明确版本兼容证据，解决 M5 可用读取路径或明确产品范围调整；这些缺口可先保留，但不能带入首版完成声明。没有新客户端证据时不重复同一恢复探针。
6. 远端 CI 与发行来源复现，最后在授权范围内安排真实接入/切换和发布。候选安装不等同旧服务可替代，现有授权包含独立合成旁路部署，不含推送/发布/真实额度调用。

每个闭环由主 Agent 实现和定向验证，出口集中 review/修复/必要完整验证，前端实际操作验收。上述顺序不扩大 M7 范围；多架构、多管理员和多上游继续延期。

Desktop 界面、真实订阅/Images 兼容、M5 恢复缓存、目标弱服务器容量、实际旧服务迁移/切换与完整替代尚未验收；M2/M4/M5/M6 完整里程碑与首版整体均不标完成。GitHub 无凭证 CI/候选工作流尚未远程运行；无远程承接、推送或发布；授权的独立合成旁路部署见最新出口。
