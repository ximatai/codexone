# 当前状态

更新时间：2026-10-22（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

M0、M1 已完成本机验收与提交后 review/修复。M2 保留 Desktop 界面验收和恢复契约缺口；按用户授权先推进不依赖它们的 M3。M3 与 M4 的代码、集中 review 和本地合成环境阶段出口已完成。M4 的 Desktop 图片操作与真实订阅兼容仍未验收，完整里程碑不标完成。M5 已复核恢复读取契约，证据仍不足，保持未完成；按用户授权推进独立 M6，当前 v8 候选安装升级/兼容回退和合成迁移切回、真实本地 TLS 反代/HTTPS 管理，以及安全快照恢复/审计基线、主密钥多版本维护及低磁盘保护/必要运行观测闭环已完成本机实现与验收；本轮跨平台出口证据见下，M6 整体仍未完成。

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

## 最新验证与范围

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

M6 已覆盖以下本机闭环：当前 v8 Linux amd64 可追溯 OCI 候选/私有初始化/受控安装升级、同卷兼容二进制回退及合成旧服务迁移切回；真实本地 TLS/Nginx 与 HTTPS 管理操作；安全快照恢复、缺失区间和审计额度基线；active/decrypt-only 多版本主密钥、先备份的分页 CAS 再加密/显式续作及旧备份依赖核对；低磁盘分级保护、结算储备与必要运行观测。当前 schema v8，旧 v7 bundle 可验证/恢复并显式升级，不兼容旧 schema 二进制原地回退，已验兼容 v8 peer 可保留同卷责任。下一项是容量演练；本地 TLS 通过不替代用户实际域名/证书部署验收。

2026-10-22 计划复盘校准：M6 剩余项同时包含实现和验收，不能理解为只需再跑测试。当前已提供安全快照 backup/restore/status/reconcile、多版本 keyring/可恢复再加密与旧备份解密依赖核对。完整清单、外部 raw 恢复审计和销毁事实仍须操作者负责，工具不能发现未知副本或证明外部审计。低磁盘分级退让/停止准入/结算预留及必要资源/WAL 观测已完成本机闭环，目标容量仍待验收。依据 O03/O04/O09/O10/O14，后续按业务闭环推进：

1. 真实本地 TLS 反代与 HTTPS 管理操作：本地阶段出口已完成，证据见上；用户实际部署仍单独验收。
2. 可维护数据与密钥：安全快照/旧快照维护态/缺失区间与审计基线，以及主密钥多版本、备份依赖与可恢复再加密已实现。维护、兼容二进制回退与旧服务切换分别验收。
3. 低磁盘保护与必要运行观测：本地阶段出口已完成，覆盖拒绝新工作、关键收尾、WAL 与备份空间不足；不替代目标宿主容量演练。
4. 当前 v8 候选及安装/升级/兼容回退、合成迁移切回已完成本机闭环；下一步在可解释的宿主约束下集中进行混合负载、图片峰值、断流、长压和资源回稳容量演练。M5 缓存未实现时只验证现有能力，含缓存的完整 O14 出口仍保留。
5. 补齐 Desktop/真实订阅的明确版本兼容证据，解决 M5 可用读取路径或明确产品范围调整；这些缺口可先保留，但不能带入首版完成声明。没有新客户端证据时不重复同一恢复探针。
6. 远端 CI 与发行来源复现，最后在授权范围内安排真实接入/切换和发布。候选安装不等同旧服务可替代，现有授权不含推送/部署/真实额度调用。

每个闭环由主 Agent 实现和定向验证，出口集中 review/修复/必要完整验证，前端实际操作验收。上述顺序不扩大 M7 范围；多架构、多管理员和多上游继续延期。

Desktop 界面、真实订阅/Images 兼容、M5 恢复缓存、目标弱服务器容量、实际旧服务迁移/切换与完整替代尚未验收；M2/M4/M5/M6 完整里程碑与首版整体均不标完成。GitHub 无凭证 CI/候选工作流尚未远程运行；无远程承接、推送、发布或部署。
