# 当前状态

更新时间：2026-10-22（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

M0、M1 已完成本机验收与提交后 review/修复。M2 保留 Desktop 界面验收和恢复契约缺口；按用户授权先推进不依赖它们的 M3。M3 与 M4 的代码、集中 review 和本地合成环境阶段出口已完成。M4 的 Desktop 图片操作与真实订阅兼容仍未验收，完整里程碑不标完成。M5 已复核恢复读取契约，证据仍不足，保持未完成；按用户授权推进独立 M6，Linux 候选安装/升级闭环已完成本机实现与验收，M6 整体仍未完成。

- M1：SQLite v1 空库迁移、实例锁、WAL/FULL、三层准入/持久 intent、对象归属屏障、累计证据幂等结算及重启 unknown 恢复；有界 DB 命令与 Runtime finalizer。M1 使用合成身份；M2 的协议实现和 M3 的账号/权限/观测进度见下方，Desktop 与恢复缺口继续保留。

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

订阅池 HTTP 使用 `CODEXONE_ACCOUNT_POOL_CONFIG` 私有模型/profile 配置，并要求管理凭证、账号主密钥和数据目录；与旧单身份配置互斥，配置见[账号凭证](docs/development/account-credentials.md)。

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

Linux amd64 候选构建、私有初始化与受控安装入口见 [Linux 安装](docs/development/linux-installation.md)。安装后用 `python3 compose-install.py <command>`，不要绕过入口使用裸 Compose；可用 `python3 scripts/verify_installation.py --image <candidate> --browser` 验证实际镜像与 Chrome 管理操作。

实际管理 UI 的合成端到端检查（先完成后端及 web 生产构建）：

```sh
python3 scripts/verify_admin_ui.py --binary .build/debug/codexone
python3 scripts/verify_account_admin_ui.py --binary .build/debug/ExecutionProbe
python3 scripts/verify_images.py --binary .build/debug/codexone --browser
```

`--chrome` 使用本机已安装 Chrome 的全新临时上下文，不使用用户浏览数据。标准 Chromium 路径先在 web 下执行 `npx playwright install chromium --only-shell`，再执行 `./scripts/verify.sh --web`（从仓库根目录）；无参数执行全部验证。各层检查定义见 [verification](docs/development/verification.md)。

## 最新验证与范围

2026-10-22，M5 契约复核与独立 M6 候选安装阶段出口：

- 实际 CLI 0.163.0 隔离 EOF 探针再次证明 reconnect 产生新生成（原 unknown、新 settled）；公开 GET response/消费位置协议不足以证明目标 Codex/订阅读取可用。M5 未实现正文缓存，未改变 unknown、重试或退款语义。见[契约证据](docs/changes/recovery-contract-audit/verification.md)。
- macOS arm64：私有初始化、0700/0600、覆盖/链接/输入拒绝、实际二进制配置及秘密权限拒绝通过；Linux amd64 的 root 初始化/显式非 root 归属亦通过。受控 launcher 直接接收污染环境仍固定私有 file/env/project/image/volume，实际安装与升级均通过该入口。
- Linux amd64 / Swift 6.4.1：多阶段 OCI release 构建及无网络实际 HTTP/SSE/WS/Images 失败路径通过；运行二进制 SHA-256 `b323209f9302e4ae36a0de4732f1a016e359fb1e522fe1649cf8e929e42cd675` 与 socket 验证产物一致。工具链基底固定 digest，附源码 revision、许可证与生产依赖 notices；CI 候选工作流仅定义，未远程运行。
- 实际本地 Linux OCI/Compose：非 root/只读/能力清零、私有本地卷、配置拒绝、live/ready、SPA/session/CSRF/Key、在线实例锁、v5 普通启动拒绝、私有一致性备份/显式幂等迁移、重启数据保留、优雅退出均通过；目录读取失败和归属不符均拒绝且不改已有数据。macOS 共享 bind 的 flock 不可靠，默认 data 因此选 Linux Engine 本地卷，不能以共享盘通过冒充锁验收。
- 实际打包 SPA 的 Chrome 1440 大屏登录、发 Key、关闭一次性秘密、刷新持久与登出通过，截图已查看；隔离 curl relay 不是实际 TLS/Nginx 验收。Swift/前端产品源码未变，沿用 M4 完整测试证据，不重复全集。

集中 review 修复了宿主 Compose 覆盖导致误选安装的问题；命令、失败取舍与复审证据见[候选验证](docs/changes/linux-distribution/verification.md)。验证均为本机合成资料，没有真实账号调用、额度消耗、推送、发布或用户服务器部署。候选产物保存在忽略的 `artifacts/linux-candidate/`，包含镜像/精确源码归档、标识和 SHA256SUMS；仅为本机候选。

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

M6 已交付第一个独立闭环：Linux amd64 可追溯 OCI 候选、私有初始化与受控 Compose、真实安装/管理/显式升级备份、候选 CI 定义与操作文档。下一项是独立的真实本地 TLS 反代业务闭环：按安装模板验收 SSE/WS、取消、负载大小与超时，并实际操作 HTTPS 管理台。

2026-10-22 计划复盘校准：M6 剩余项同时包含实现和验收，不能理解为只需再跑测试。当前命令入口只有配置检查/迁移，尚无旧快照 restore/reconcile 维护流程；账号密文有单主密钥标识，但尚无 active/decrypt-only 多版本轮换与可恢复再加密流程。低磁盘分级退让/停止准入/结算预留，以及运行资源与 WAL 的容量观测，也须落实并验证。依据 O03/O04/O09/O10/O14，后续按业务闭环推进：

1. 真实本地 TLS 反代与 HTTPS 管理操作，交付可使用的对外接入。
2. 可维护数据与密钥：独立备份/恢复、维护态、缺失执行区间及审计额度基线核对、兼容二进制回退；补齐主密钥版本维护和备份解密依赖。不能用已有迁移前备份替代这些能力。
3. 低磁盘保护与必要运行观测，证明拒绝新工作时仍保住核心执行责任与结算，并覆盖 WAL/备份空间不足。
4. 在可解释的目标宿主约束下集中进行混合负载、图片峰值、断流、长压和资源回稳验收。M5 缓存未实现时只验证现有能力，含缓存的完整 O14 出口仍保留。
5. 补齐 Desktop/真实订阅的明确版本兼容证据，解决 M5 可用读取路径或明确产品范围调整；这些缺口可先保留，但不能带入首版完成声明。没有新客户端证据时不重复同一恢复探针。
6. 独立合成旧服务迁移/切回演练、远端 CI 与发行来源复现，最后在授权范围内安排真实接入/切换和发布。候选安装不等同旧服务可替代，现有授权不含推送/部署/真实额度调用。

每个闭环由主 Agent 实现和定向验证，出口集中 review/修复/必要完整验证，前端实际操作验收。上述顺序不扩大 M7 范围；多架构、多管理员和多上游继续延期。

Desktop 界面、真实订阅/Images 兼容、M5 恢复缓存、目标弱服务器容量、完整恢复/回退与旧服务替代尚未验收；M2/M4/M5/M6 完整里程碑与首版整体均不标完成。GitHub 无凭证 CI/候选工作流尚未远程运行；无远程承接、推送、发布或部署。
