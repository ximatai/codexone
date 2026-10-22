# 当前状态

更新时间：2026-10-22（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

M0、M1 本机验收与提交后 review/修复/复审已完成。M1 共关闭五项 review 问题，复审确认可进入 M2；验证范围见 [持久执行记录](docs/changes/persistent-execution/verification.md)。

- M1：SQLite v1 空库迁移、实例锁、WAL/FULL、三层准入/持久 intent、对象归属屏障、累计证据幂等结算及重启 unknown 恢复；有界 DB 命令与 Runtime finalizer。M1 使用合成身份；M2 的 HTTP/WS 传输与前台模式切片开发中，具体进度见下方，尚未完成整个 M2。

- 核心骨架可编译运行：Core / Adapters / Runtime / 入口四个 Swift targets，依赖方向由检查脚本约束；Swift 6.4 严格并发，锁定 Package.resolved。
- NIO 数据健康入口、Vapor 管理健康 API、配置校验和 ServiceLifecycle 信号/子服务监督。默认仅 loopback；执行未配置时 readiness 为 503，生成请求明确拒绝。
- React/TS/Vite 服务概览，按 feature 聚合 UI/API/测试；Vitest/Testing Library 与 Playwright，前后端共用健康契约样例。Node 22.23.0，npm lock 固定依赖。
- 本地分支 `codex/account-governance`；未关联远程/推送，未改动用户服务器或旧项目。完成的提案在归纳后回收，过程可由 Git 追溯。

## 运行与检查

后端（默认数据端口 18080，管理 18081）：

```sh
swift run codexone --check-config
swift run codexone
```

受控单身份配置与合成验证见[单身份配置](docs/development/single-identity.md)。

环境变量 `CODEXONE_DATA_PORT` / `CODEXONE_ADMIN_PORT` 可指定端口，0 为临时端口；非零端口不得相同。无配置时也能启动健康入口，但不能代理生成。

可选 `CODEXONE_DATA_DIRECTORY` 指向绝对数据目录，可初始化/恢复核心库并标记存储先决条件就绪；默认不创建持久库，配置存储也不会启用生成。Linux 构建需 `libsqlite3-dev`，macOS 使用系统 SQLite。

前端（另一个终端；开发代理指向管理默认端口）：

```sh
cd web
npm ci --ignore-scripts --no-audit --no-fund
npm run dev
```

仓库根目录验证：

```sh
./scripts/verify.sh --backend
./scripts/verify.sh --web --chrome
```

`--chrome` 使用本机已安装 Chrome 的全新临时上下文，不使用用户浏览数据。标准 Chromium 路径先在 web 下执行 `npx playwright install chromium --only-shell`，再执行 `./scripts/verify.sh --web`（从仓库根目录）；无参数执行全部验证。各层检查定义见 [verification](docs/development/verification.md)。

## 最新验证与范围

- 2026-10-21 文档范围同步：已按实际使用需求更新[里程碑](docs/plans/roadmap.md)及相关规范，首版替代验收覆盖 Desktop、图片编辑、额度统计、迁移及弱服务器。`python3 scripts/check_docs.py` 与 `git diff --check` 通过；本次仅改文档，未进行运行兼容/容量/迁移验收，未访问或改动 用户服务器。

- 本机 macOS arm64 / Swift 6.4：后端统一验证通过，含模块边界、严格格式、构建、四个 Swift Testing targets，以及真实进程/HTTP/端口检查。
- 80 个 Swift 测试函数通过（其中无效配置含 7 个参数案例，旧库拒绝含 2 个参数案例）：真实 SQLite 竞争/幂等/超额/跨窗口暴露/实例锁/schema/事务及只读失败、128 条后最终用量及压缩水位，以及 finalizer 满载失败/移交/关闭、观察用量后取消和过时最终化；另覆盖就绪、共享 DTO、HTTP/请求限制、模型 profile/策略指纹、配置、子服务失败、父取消和真实 HTTP 关闭后重新绑定。包括托管 Key 的 CAS/撤销/轮换与限额连续性、审计回滚/容量及满普通审计后全部 256 个 Key 仍可撤销；管理 session 来源/CSRF/过期/容量/重启与静态快照/文件安全边界；账号凭证 AEAD/主密钥文件、刷新 CAS/禁用/提交回滚/重启/审计结束预留及 v1/v2 显式升级；Runtime 共享刷新等待者取消/容量/并行/期限/关闭与故障 DB 停止新刷新。
- M1 真实子进程 SIGKILL 在 intent 前后、绑定后及结算后重启通过，验证 unknown/归属/预留及重复结算；不是掉电或 Linux 验证。配置存储的真实网关启动/锁冲突/脱敏错误/关闭重开通过。
- 进程检查通过：合成路径/查询/请求头/正文不进入输出、脱敏配置拒绝、两个入口 live/ready、未配置生成拒绝、请求体限制、SIGTERM 关闭空闲 keepalive 和未完成请求/释放端口、部分启动失败收敛。
- 前端类型/生产构建、15 个组件/API 测试及 3 个概览 Playwright Chrome 155.0.8059.85 测试通过；概览 API 为合成拦截。新增真实 Chrome 接生产 SPA/临时网关/合成上游的 Key 操作检查：安全 Cookie 登录、创建/复制/清除、模型与限额实际执行、CAS、禁用轮换不重置计数、读取失败重试、已提交但响应丢失后的核对和登出失败重试；登录/编辑/列表大屏截图已查看。没有使用个人浏览状态或真实账号，不能代替 Desktop 验收。
- 2026-10-22 独立 Linux amd64/Swift 6.4 本地 Docker 验证通过（快照 8184adb，模拟执行）：单并发后端完整检查、26 Swift 测试及进程/权限/四个 SIGKILL 场景。首次双并发因约 2.8 GiB Docker VM 内存不足 OOM；未改全局设置。此结果不代表弱服务器容量验收。
- 2026-10-22 M2 Linux amd64/Swift 6.4 本地容器完整验证通过至 fcd3a5e（38 Swift 测试、进程故障、九组 HTTP/SSE、九组 WS、context、profile 及 v2 压缩场景），单并发、2 CPU/2500 MiB。macOS 实际 CLI 0.163.0 通过明确模型指导的目录采用、HTTP/SSE 文本/函数结果与加密推理回传、缺 profile fallback、EOF 新执行，以及直连/桥接/原生 WS 区分检查；独立临时配置，无真实账号。
- Linux amd64 与配套 Chromium 的无凭证 GitHub CI 定义已建立，尚未远程运行。未访问真实账号/上游、未部署。

## 下一步与未覆盖

M2 开发中：HTTP JSON/SSE、原生 WS 默认/命名 lane、HTTP→WS 桥接，以及 warmup/compact、加密上下文指纹归属和客户端 namespace/custom 工具的合成闭环已实现。各切片提交后 review 的问题均已亲自修复、复验及复审；详细范围和验证账见[单身份协议](docs/changes/single-identity-protocol/verification.md)。

模型目录提供白名单的 OpenAI 视图；全部模型有明确 profile 才同时提供同集合的 Codex 视图。顺序/策略版本 P2 和空指导清空客户端基线的 P1 已关闭：显式非空 catalog.baseInstructions，不自动编写/复制默认提示。缺 profile 的 Codex 目录请求返回 503，客户端仍可能 fallback，不能当目录验收通过。b3ad1f1 复审、macOS/Linux 完整后端和实际 CLI 三模式均通过。EOF 后原 attempt 保持 unknown，不能当原输出恢复；[恢复契约证据](docs/evidence/client-recovery.md)已记录。

实际 CLI 传输补充：发现可选扩展提议被拒造成 WS 握手失败并自动 HTTP fallback，已改为忽略提议、不协商压缩，RSV 仍拒绝。de0957a 已复审并通过 macOS/Linux 完整后端，reviewer 独立重跑三传输 CLI 与九组 WS。原生同一 socket 一次预热、两次生成及 previous_response_id 连续链已核实，均持久结算；Desktop 仍未验收。

M2 v2 压缩切片：支持普通 Responses 上的末尾 compaction_trigger，仍按 compact 统计并执行指纹屏障；完整 encrypted_content 的客户端本地 ID 在归属校验后移除，无正文/显式引用仍严格查 ID。macOS 完整后端 38 个 Swift 测试及新 HTTP/SSE/WS 故障脚本通过；实际 CLI 0.163.0 三传输均完成工具、v2 压缩和下一请求，原文不进核心库。独立 review 的终态索引一致性 P2 已亲自修复，fcd3a5e 复审及同提交 Linux 完整验证通过。另用 Desktop 内置 CLI 0.163.0-alpha.11 独立运行标准/压缩三传输及 HTTP retry/缺 profile 共八组检查通过；这不代表 Desktop UI 或断线恢复读取验收。

M2 保留 Desktop 界面验收与恢复契约两项缺口，不标完成。2026-10-22 用户明确允许先推进不依赖它们的 M3；Computer Use 禁止控制 com.openai.codex 的限制不绕过，CLI 证据不替代 UI。恢复缓存仍须实际可使用的读取契约。

M3 多主体/Key 治理首个切片 f416278 已通过独立 review 与同提交 Linux 完整验证（45 个 Swift 测试及全部脚本，单并发、2 CPU/2500 MiB 本地模拟容器）。同一受控上游上的 Key 创建/轮换/禁用/模型范围/本地限额、HTTP/WS 当前权限与事务复核已实现；轮换不重置标识/计数。主 Agent 根据 review 提醒进一步为撤销预留审计：普通 4096 条、总 4352 条，预留仅用于实际禁用，保证全部 256 个现存 Key 仍可撤销。改进 9e78921 已复审，macOS 与同提交 Linux 完整后端 46 测试及全部脚本均通过。

管理 API 独立认证；NIO 有界管理入口把完整请求交 Vapor 路由。浏览器 session/CSRF、启动静态安全快照及 Key 业务界面 aa28016 已实现，本机后端完整验证、前端与真实 Chrome 操作通过。独立 review 发现 CAS 后刷新断网仍谎报成功的 P2，主 Agent 亲自以 3e9e010 修复并补真实浏览器回归、通过构建与 15 个测试，复审关闭；无其他阻塞问题。aa28016 同快照 Linux 完整后端 52 测试及全部脚本通过（修复未改后端），本地单并发模拟容器，非远端 CI/容量验收。配置见[托管 Key](docs/development/key-governance.md)，证据见[Key 治理](docs/changes/key-governance/verification.md)和[管理界面](docs/changes/key-management-ui/verification.md)。

正在推进[账号凭证与刷新持久屏障](docs/changes/account-credentials/proposal.md)：AES-256-GCM 信封、独立主密钥加载、Core 凭证用例和 SQLite v3 原子刷新/CAS 已实现。新增真实进程在 intent 前/后及完成后 SIGKILL，重启分别保持旧 ready、auth_uncertain、新版本 ready；bace11b 的 macOS/Linux 完整后端 60 测试和全部脚本通过。独立 review 的 slash 转义膨胀 P2 已由主 Agent 以 98f9746 修复并复审关闭，同修复 Linux 重建/4 个定向测试/三组 SIGKILL 通过，无新增阻塞。

Runtime 有界单飞 owner e7c200a 已实现并通过 macOS/Linux 完整后端 66 测试及全部脚本，含真实 ServiceLifecycle 关闭和 SQLite 状态复核；独立 review 无阻塞并重跑 6 个定向回归通过。具体订阅 OAuth HTTP 适配器已实现并通过 macOS 完整后端 73 测试及全部脚本：固定可信端点、PKCE code exchange、稳定身份等价性、刷新及真实合成 socket 的取消/总期限/重定向/容量/持久失败路径。55502bf 独立 review 无阻塞，reviewer 八项定向验证及同快照 Linux 完整后端 73 测试/全部脚本通过；不代表真实订阅或生产 TLS 验收。

初次授权 Runtime owner 与订阅桥接已实现：八流程/四并行、session owner 绑定、10 分钟期限和一次性消费、取消/关闭等待、重新授权 namespace/CAS。macOS 完整后端 77 测试和全部脚本通过，新增实际 socket 贯通后全量 Swift 78 测试通过，0be1012 独立 review 无阻塞，五项定向验证通过；主 Agent 进一步补充实际 verifier/challenge S256 一致性验证并通过。账号管理 API 与生产主密钥组装已实现，macOS 完整后端 80 测试及全部脚本通过，正在进入提交后 review；支持列表/模式 CAS、共享刷新与初次/重新授权，复用现有管理认证/CSRF，配置检查拒绝密钥复用且不建库。尚未提供账号 UI 或实际账号路由，不能当已接入订阅账号。边界见[凭证层](docs/development/account-credentials.md)，证据见[验证账](docs/changes/account-credentials/verification.md)。随后接可信提供者与账号池；M3 整体未完成，无真实账号调用。

账号可操作授权界面/真实订阅验收、账号池、Images 转发、完整管理账本查询与恢复缓存、生产镜像及长期容量均未实现；管理业务界面目前只覆盖 Key，未覆盖账号、额度、图片权限与诊断。HTTP JSON/SSE 合成闭环已实现，WS 命名 lane/桥接/预热/压缩合成闭环已实现，CLI 0.163.0 的 HTTP/SSE 文本/函数往返及加密推理回传已通过；尚未完成 M2 整体、Desktop 或真实订阅验收；不能从健康入口或骨架测试推导已支持。恢复客户端契约仍须进一步核实并验证，遇到困难/更优方案及时沟通。
