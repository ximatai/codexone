# 当前状态

更新时间：2026-10-21（Asia/Shanghai）。唯一全局状态入口。

## 项目状态

- 核心骨架可编译运行：Core / Adapters / Runtime / 入口四个 Swift targets，依赖方向由检查脚本约束；Swift 6.4 严格并发，锁定 Package.resolved。
- NIO 数据健康入口、Vapor 管理健康 API、配置校验和 ServiceLifecycle 信号/子服务监督。默认仅 loopback；执行未配置时 readiness 为 503，生成请求明确拒绝。
- React/TS/Vite 服务概览，按 feature 聚合 UI/API/测试；Vitest/Testing Library 与 Playwright，前后端共用健康契约样例。Node 22.23.0，npm lock 固定依赖。
- 本地分支 `codex/bootstrap-runtime`；未关联远程/推送，未改动 Ali 或旧项目。完成的提案在归纳后回收，过程可由 Git 追溯。

## 运行与检查

后端（默认数据端口 18080，管理 18081）：

```sh
swift run codexone --check-config
swift run codexone
```

环境变量 `CODEXONE_DATA_PORT` / `CODEXONE_ADMIN_PORT` 可指定端口，0 为临时端口；非零端口不得相同。无配置时也能启动健康入口，但不能代理生成。

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

- 2026-10-21 文档范围同步：已按实际使用需求更新[里程碑](docs/plans/roadmap.md)及相关规范，首版替代验收覆盖 Desktop、图片编辑、额度统计、迁移及弱服务器。`python3 scripts/check_docs.py` 与 `git diff --check` 通过；本次仅改文档，未进行运行兼容/容量/迁移验收，未访问或改动 Ali。

- 本机 macOS arm64 / Swift 6.4：后端统一验证通过，含模块边界、严格格式、构建、四个 Swift Testing targets，以及真实进程/HTTP/端口检查。
- 9 个 Swift 测试函数通过（其中无效配置含 7 个参数案例）：覆盖就绪、共享 DTO、HTTP/请求限制、配置、子服务失败、父取消和真实 HTTP 关闭后重新绑定。
- 进程检查通过：脱敏配置拒绝、两个入口 live/ready、未配置生成拒绝、请求体限制、SIGTERM 关闭空闲 keepalive 和未完成请求/释放端口、部分启动失败收敛。
- 前端类型/生产构建、8 个组件/API 测试、2 个 Playwright Chrome 155.0.8059.85 测试通过；浏览器 API 为合成拦截，涵盖桌面/移动及失败重试，不冒充完整真实上游端到端。
- Linux amd64 Swift 6.4 与配套 Chromium 的无凭证 GitHub CI 定义已建立，尚未远程运行。未访问真实账号/上游、未部署。

## 下一步与未覆盖

建立 SQLite 持久执行切片：版本化 schema、业务原子事务、准入 → intent → ID 归属屏障 → 幂等结算 → 重启 pending/exposure，使用真实临时库和故障路径验证。

账号授权/刷新、账号池、Responses/SSE/WS/Images 转发、持久账本与恢复缓存、管理认证/业务界面、生产镜像及长期容量均未实现；不能从健康入口或骨架测试推导已支持。具体加密库、UI 组件与恢复客户端契约在相关切片选择并验证，遇到困难/更优方案及时沟通。
