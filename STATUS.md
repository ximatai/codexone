# 当前状态

更新时间：2026-10-22（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

M0、M1 已完成本机验收与提交后 review/修复。M2 保留 Desktop 界面验收和恢复契约缺口；按用户授权先推进不依赖它们的 M3。M3 代码、集中 review 与本地合成环境阶段出口已完成，未宣称真实订阅或生产客户端验收。

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

实际管理 UI 的合成端到端检查（先完成后端及 web 生产构建）：

```sh
python3 scripts/verify_admin_ui.py --binary .build/debug/codexone
python3 scripts/verify_account_admin_ui.py --binary .build/debug/ExecutionProbe
```

`--chrome` 使用本机已安装 Chrome 的全新临时上下文，不使用用户浏览数据。标准 Chromium 路径先在 web 下执行 `npx playwright install chromium --only-shell`，再执行 `./scripts/verify.sh --web`（从仓库根目录）；无参数执行全部验证。各层检查定义见 [verification](docs/development/verification.md)。

## 最新验证与范围

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

下一里程碑是 M4 图片生成/参考图编辑及独立权限闭环。Desktop 界面验收、恢复读取契约和真实订阅兼容仍明确保留；Images、恢复缓存、生产镜像/弱服务器容量、升级/迁移/回退替代演练尚未交付。GitHub 无凭证 CI 定义存在，但尚未远程运行；无远程承接或推送。首版整体未完成。
