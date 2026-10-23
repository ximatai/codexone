# 当前状态

更新时间：2026-10-24（Asia/Shanghai）。只保留当前快照；阶段过程由 Git 追溯，验证依据在对应证据页。

## 项目状态

**首要前置项是订阅接入范围。** [SIWC条款](https://openai.com/policies/sign-in-with-chatgpt-terms/)限制通用API转接、订阅池化/共享和绕限；现有旧客户端身份/订阅后端实现不等同于[官方自定义客户端授权](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)。通用网关优先评估[正式API及商业协议](https://openai.com/policies/services-agreement/)；若保留订阅用途，需先调整产品范围并确认授权。远程凭证持久存储条款与[自托管VM指南](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)表述冲突，须官方书面澄清。技术测试通过不代表平台许可，安全能力准入也不代替订阅转接授权。

| 阶段 | 已有实现与证据 | 仍未完成 |
|---|---|---|
| M0/M1 | 本机骨架、SQLite持久执行/归属/结算与恢复责任闭环 | 不据此宣称首版可替代旧服务 |
| M2 | HTTP JSON/SSE、桥接/native WS、模型/profile、工具/上下文/压缩；固定CLI合成操作与限定Desktop合成文本通过 | 真实订阅Desktop操作及M5恢复读取 |
| M3 | 管理登录/CSRF、Key、账号授权/刷新、路由及用量观测的本机合成闭环 | 订阅池受条款约束；真实账号池/刷新未验收 |
| M4 | Images生成/编辑及Responses图片工具、权限与计量的本机合成闭环 | 真实Desktop图片、参考图、连续编辑及真实提供者图片 |
| M5 | 已核对恢复关联及已有输出读取的限定实验 | 正式恢复读取契约不充分，未实现生产正文缓存 |
| M6 | schema v8候选安装/升级/兼容回退、合成迁移切回、TLS、快照/密钥维护、低盘保护及容量样本 | 完整O14/目标弱宿主、async任务观测、实际旧服务替代、远程CI与发行 |

M2/M4/M5/M6及首版整体不标完成。多架构、多管理员和多上游继续延期。

## 最新验证与范围

| 日期/对象 | 已验证范围 | 依据 |
|---|---|---|
| 2026-10-24 · 候选2336499，产品修正17e625b | macOS arm64 Swift203项及受影响协议/WS/Images/压缩；独立HTTP73/WS128共201次；Linux amd64完整verification及实际OCI/Compose安装 | [文本协议验证](docs/evidence/text-protocol-validation.md) |
| 2026-10-24 · 真实订阅HTTP/SSE | 单模型/选定参数、完整输出窗口两轮；内容、上下文、终态用量与持久账本一致 | [真实调用与责任账](docs/evidence/real-subscription-validation.md) |
| 2026-10-23 · Desktop 26.1016.62342 | 用户在另一设备保持原配置，新会话显示预期合成回复；修复工具说明容量后与执行账本关联 | [Desktop诊断](docs/changes/desktop-operation-diagnosis/verification.md) |
| 2026-10-23 · 管理前端与固定CLI | 管理UI合成OAuth/Key/用量操作及Chrome大屏检查；固定CLI默认目录、Lite工具、三传输、工具往返及压缩 | [管理操作](docs/changes/desktop-test-readiness/verification.md)、[默认客户端](docs/changes/default-client-loop/verification.md) |
| 2026-10-22/23 · 容量与运维 | HTTP/native WS各600秒混合样本、keepalive/长寿命turn、最大图片边界；v8维护/切回与实际TLS | [容量](docs/changes/capacity-rehearsal/verification.md)、[长执行](docs/changes/long-task-profiles/verification.md)、[运维](docs/changes/v8-release-transition/verification.md) |

历史阶段的测试数、旧候选指纹和“当时尚未运行”不作为当前状态。上述记录不扩大到其他客户端版本、真实native WS/工具/图片/密文推理、订阅参数组合或所有输出视图一致性；[协议矩阵](docs/evidence/text-protocol-matrix.md)与[恢复证据](docs/evidence/client-recovery.md)给出适用边界。

## 候选、部署与账本

- 最新本地归档为`artifacts/usage-metadata/`，来源2336499；验证、runtime及隔离服务器运行程序摘要一致，详见文本验证。未将其切换为公开服务。
- 最近一次已核对的公开测试服务为56600c0，仍使用合成上游；保留原Key/数据和回退材料。真实Desktop合成文本证据只适用于上表版本与操作，不代表实时服务巡检。
- 受控真实生成累计8/8次：4笔历史未知（最早原库被旧探针误清理，仅留脱敏外部记录）、2笔完整计量失败、2笔成功。保留5份历史库和最终两笔共用库及私有本机副本，不用成功抵销失败/未知；详细摘要只见真实调用账。该轮不再追加生成。
- 隔离真实实例已回收、临时访问/管理秘密已清除；最后检查旧服务healthy、身份/运行指纹未变，原合成入口前后ready。未修改旧账号文件或调用refresh。
- 本地分支`codex/account-governance`；无远程承接、推送或发布，无正式旧服务切换。私有部署位置和凭证不进入公开仓库。

## 运行与检查

后端（默认数据端口 18080，管理 18081）：

```sh
swift run codexone --check-config
swift run codexone
```

受控单身份配置与合成验证见[单身份配置](docs/development/single-identity.md)。

环境变量 `CODEXONE_DATA_PORT` / `CODEXONE_ADMIN_PORT` 可指定端口，0 为临时端口；非零端口不得相同。无配置时也能启动健康入口，但不能代理生成。

现有订阅池代码的配置入口（不代表条款准入）：HTTP 使用 `CODEXONE_ACCOUNT_POOL_CONFIG` 私有模型/profile 配置，并要求管理凭证、账号主密钥和数据目录；与旧单身份配置互斥，配置见[账号凭证](docs/development/account-credentials.md)。

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

1. 先决定接入路线：正式API通用网关，或用途收窄且获准的订阅应用。后续真实订阅接入与公开上线以条款确认/范围调整为前置；既有技术验证不扩大调用或部署授权。
2. 路线明确后，再按对应官方契约补普通输出多视图关联、请求参数及错误/健康边界；保留归属、可信用量、unknown和无自动重放约束。
3. 单独准备明确版本的真实Desktop文本/工具/图片操作；脚本、CLI和合成服务均不替代实机验收。恢复读取继续受M5契约约束，没有新证据不重复旧探针。
4. 补目标宿主及共存服务容量、async任务观测和其余图片组合，再完成远程CI/发行来源复现。推送、发布和正式切换仍依明确授权。

配置与维护分别见[Key治理](docs/development/key-governance.md)、[账号凭证](docs/development/account-credentials.md)、[快照维护](docs/development/snapshot-maintenance.md)、[主密钥维护](docs/development/master-key-maintenance.md)。迁移或回退须保留新执行责任及解密依赖，不能恢复旧余额或原地降schema。
