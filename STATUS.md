# 当前状态

更新时间：2026-10-22（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

M0、M1 本机验收与提交后 review/修复/复审已完成。M1 共关闭五项 review 问题，复审确认可进入 M2；验证范围见 [持久执行记录](docs/changes/persistent-execution/verification.md)。

- M1：SQLite v1 空库迁移、实例锁、WAL/FULL、三层准入/持久 intent、对象归属屏障、累计证据幂等结算及重启 unknown 恢复；有界 DB 命令与 Runtime finalizer。M1 使用合成身份；M2 已实现 HTTP JSON/SSE 合成纵向切片，该切片提交后 review 的三项 P1 已修复并复审通过，尚未完成整个 M2。

- 核心骨架可编译运行：Core / Adapters / Runtime / 入口四个 Swift targets，依赖方向由检查脚本约束；Swift 6.4 严格并发，锁定 Package.resolved。
- NIO 数据健康入口、Vapor 管理健康 API、配置校验和 ServiceLifecycle 信号/子服务监督。默认仅 loopback；执行未配置时 readiness 为 503，生成请求明确拒绝。
- React/TS/Vite 服务概览，按 feature 聚合 UI/API/测试；Vitest/Testing Library 与 Playwright，前后端共用健康契约样例。Node 22.23.0，npm lock 固定依赖。
- 本地分支 `codex/single-identity-protocol`；未关联远程/推送，未改动用户服务器或旧项目。完成的提案在归纳后回收，过程可由 Git 追溯。

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
- 32 个 Swift 测试函数通过（其中无效配置含 7 个参数案例，旧库拒绝含 2 个参数案例）：新增真实 SQLite 竞争/幂等/超额/跨窗口暴露/实例锁/schema/事务及只读失败、128 条后最终用量及压缩水位，以及 finalizer 满载失败/移交/关闭、观察用量后取消和过时最终化；另覆盖就绪、共享 DTO、HTTP/请求限制、配置、子服务失败、父取消和真实 HTTP 关闭后重新绑定。
- M1 真实子进程 SIGKILL 在 intent 前后、绑定后及结算后重启通过，验证 unknown/归属/预留及重复结算；不是掉电或 Linux 验证。配置存储的真实网关启动/锁冲突/脱敏错误/关闭重开通过。
- 进程检查通过：合成路径/查询/请求头/正文不进入输出、脱敏配置拒绝、两个入口 live/ready、未配置生成拒绝、请求体限制、SIGTERM 关闭空闲 keepalive 和未完成请求/释放端口、部分启动失败收敛。
- 前端类型/生产构建、9 个组件/API 测试、3 个 Playwright Chrome 155.0.8059.85 测试通过；浏览器 API 为合成拦截，涵盖桌面/移动、失败重试及真实浏览器 10 秒超时后重试；桌面正常/超时截图已人工查看，不冒充完整真实上游端到端。
- 2026-10-22 独立 Linux amd64/Swift 6.4 本地 Docker 验证通过（快照 8184adb，模拟执行）：单并发后端完整检查、26 Swift 测试及进程/权限/四个 SIGKILL 场景。首次双并发因约 2.8 GiB Docker VM 内存不足 OOM；未改全局设置。此结果不代表弱服务器容量验收。
- Linux amd64 与配套 Chromium 的无凭证 GitHub CI 定义已建立，尚未远程运行。未访问真实账号/上游、未部署。

## 下一步与未覆盖

M2 开发中，HTTP/SSE 切片已通过本机后端及真实管理界面联调，提交后 review 的三项 P1 及 Linux CRLF 差异已修复、复审与修复快照 Linux 完整验证通过；原生 WS 默认串行 lane 与 HTTP→WS 桥接已通过本机完整回归，待提交后 review，下一步命名 lane、预热/压缩与客户端兼容。入口见[单身份协议任务](docs/changes/single-identity-protocol/tasks.md)。先接通持久执行与无凭证合成 HTTP/SSE/WS 路径，再验收明确版本客户端。M1 独立 Linux 验证已完成，不把本地容器测试当作远端 CI 通过。

账号授权/刷新、账号池、WS 命名 lane/预热/压缩与 Images 转发、完整管理账本查询与恢复缓存、管理认证/业务界面、生产镜像及长期容量均未实现；HTTP JSON/SSE 合成闭环已实现，WS 串行/HTTP 桥接合成闭环已实现，尚未完成 M2 整体或真实客户端验收；不能从健康入口或骨架测试推导已支持。具体加密库、UI 组件与恢复客户端契约在相关切片选择并验证，遇到困难/更优方案及时沟通。
