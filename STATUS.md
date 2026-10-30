# 当前状态

更新时间：2026-10-30（Asia/Shanghai）。只保留当前快照；阶段过程由 Git 追溯，验证依据在对应证据页。

## 项目状态

| 阶段 | 已有实现与证据 | 仍未完成 |
|---|---|---|
| M0/M1 | 本机骨架、SQLite持久执行/归属/结算与恢复责任闭环 | 不据此宣称首版可替代旧服务 |
| M2 | HTTP JSON/SSE、桥接/native WS、模型/profile、工具/上下文/压缩；协议[开放透传](docs/changes/open-protocol-passthrough/proposal.md)与[模型目录透传](docs/changes/model-catalog-passthrough/proposal.md)；真实Desktop+真实订阅三模型对话、视觉输入、工具往返通过 | 压缩、长任务/中断恢复的真实验收及M5恢复读取 |
| M3 | 管理登录/CSRF、Key（含[显式无限额](docs/changes/unlimited-key-limits/proposal.md)）、账号授权/刷新、路由及用量观测；真实OAuth授权、额度观测与单Key摘要导入已在测试实例使用 | 多账号路由、长期刷新、全部Key正式迁移与切回 |
| M4 | Images生成/编辑及Responses图片工具、权限与计量的本机合成闭环 | 与旧服务对齐的图片模型映射、真实Desktop图片生成、参考图、连续编辑 |
| M5 | 已核对恢复关联及已有输出读取的限定实验 | 正式恢复读取契约不充分，未实现生产正文缓存 |
| M6 | schema v8候选安装/升级/兼容回退、合成迁移切回、TLS、快照/密钥维护、低盘保护及容量样本 | 完整O14/目标弱宿主、async任务观测、实际旧服务替代、远程CI与发行 |

M2/M4/M5/M6及首版整体不标完成。多架构、多管理员和多上游继续延期。

## 最新验证与范围

| 日期/对象 | 已验证范围 | 依据 |
|---|---|---|
| 2026-10-30 · 代码a8a3e1b测试实例 | Linux amd64 release及全部Docker无网络verification通过；部署后真实Desktop新会话（原Key改地址）三模型对话、视觉输入、本地命令工具成功，当日17次准入全部完整结算；冒烟2次真实调用 | [Desktop验收](docs/changes/open-protocol-passthrough/verification.md) |
| 2026-10-30 · 目录透传与无限额 | macOS arm64 `verify.sh --backend`（Swift 206项）及 `--web --chrome` 通过 | [目录](docs/changes/model-catalog-passthrough/verification.md)、[无限额](docs/changes/unlimited-key-limits/verification.md) |
| 2026-10-24 · 代码9dd0d07 | macOS arm64完整后端及Swift205项；独立输出HTTP88/WS168共256次、参数314次、既有文本201次；Linux amd64 release与全部Docker无网络verification通过 | [输出与参数验证](docs/evidence/ordinary-output-parameters.md) |
| 2026-10-24 · 真实订阅HTTP/SSE | 单模型/选定参数、完整输出窗口两轮；内容、上下文、终态用量与持久账本一致 | [真实调用与责任账](docs/evidence/real-subscription-validation.md) |
| 2026-10-23 · Desktop 26.1016.62342 | 用户在另一设备保持原配置，新会话显示预期合成回复；修复工具说明容量后与执行账本关联 | [Desktop诊断](docs/changes/desktop-operation-diagnosis/verification.md) |
| 2026-10-23 · 管理前端与固定CLI | 管理UI合成OAuth/Key/用量操作及Chrome大屏检查；固定CLI默认目录、Lite工具、三传输、工具往返及压缩 | [管理操作](docs/changes/desktop-test-readiness/verification.md)、[默认客户端](docs/changes/default-client-loop/verification.md) |
| 2026-10-22/23 · 容量与运维 | HTTP/native WS各600秒混合样本、keepalive/长寿命turn、最大图片边界；v8维护/切回与实际TLS | [容量](docs/changes/capacity-rehearsal/verification.md)、[长执行](docs/changes/long-task-profiles/verification.md)、[运维](docs/changes/v8-release-transition/verification.md) |

历史阶段的测试数、旧候选指纹和“当时尚未运行”不作为当前状态。上述记录不扩大到其他客户端版本、真实native WS/工具/图片/密文推理、真实订阅参数及未纳入所选契约的输出组合；[协议矩阵](docs/evidence/text-protocol-matrix.md)与[恢复证据](docs/evidence/client-recovery.md)给出适用边界。

## 测试部署与账本

2026-10-30 经用户授权，在其服务器部署隔离测试实例（独立目录、数据卷、管理凭证与证书，数据/管理入口分离的HTTPS反代），与旧服务并行；旧服务及其路由、其他Nginx站点未修改。镜像本机构建后上传，服务器不编译、不拉取镜像。服务器地址、域名、凭证与Key映射只在私有部署目录，不进入仓库。

- 订阅账号经管理台全新OAuth授权，不复用旧服务refresh token（轮换token一次性，共用会互相作废）。
- 旧服务全部Key以摘要离线导入且默认禁用，仅启用用户选定的一枚；其余待正式迁移。冒烟用临时Key已禁用。
- 2026-10-24回收的旧测试实例账本已私下归档：真实生成累计9次（5未知、2完整计量失败、2成功），回收不改变其结算与未知责任。
- 当前分支`codex/account-governance`在私有远程`origin`的位置为d31e3c0，其后本地提交（目录透传、无限额、构建镜像源及本次记录）尚未推送；无远程CI，无正式旧服务切换。

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

## 当前交付与下一步

测试实例已通过真实Desktop文本/视觉/工具验收。下一步按顺序：图片生成与旧服务对齐（每个图片模型一个hostModel、图片历史与压缩拒绝问题）后真实Desktop图片闭环；数据面连接上限（当前8）评估；全部Key正式迁移与切回预案。构建侧若Rosetta下swift-build再次死锁，评估以本地镜像GNU SDK交叉编译。真实调用、推送与部署仍须用户授权。

配置与维护分别见[Key治理](docs/development/key-governance.md)、[账号凭证](docs/development/account-credentials.md)、[快照维护](docs/development/snapshot-maintenance.md)、[主密钥维护](docs/development/master-key-maintenance.md)。迁移或回退须保留新执行责任及解密依赖，不能恢复旧余额或原地降schema。
