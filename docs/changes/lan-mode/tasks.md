# 任务：局域网模式

契约见 [proposal](proposal.md)。

- [x] 监听地址与来源网段配置、校验及真实 socket 测试。
- [x] 局域网 HTTP 管理会话 cookie 与 origin 规则，回归 HTTPS/回环行为。
- [x] 初始化 `--lan`/`--lan-allow`、风险输出与安装验证。
- [x] 系统状态传输模式与管理界面常驻风险提示，浏览器验收。
- [x] README、安装指南、客户端接入与规范同步。
- [ ] 测试环境真实 Codex 客户端 HTTP/WS 验收。

## 验收记录（2026-11-01）

本机 macOS 27.2 arm64、Apple Swift 6.4.2、Node 22.22.0、Python 3.9.6、Chrome 156.0.8078.80。Node 与贡献指南固定的 22.23.0 有小版本差异；未运行 Linux/容器构建、SSH/远端部署操作或调用真实提供者端点。

- 配置表覆盖全部允许范围、100.64/10、IPv6、范围边界、主机名/公网/通配/zone ID/非规范 IPv4、畸形及扩大范围的 CIDR、HTTP origin 不匹配；进程验证退出 78 且不回显值。
- 三种传输入口通过真实 socket 检查第二监听、静默越界 peer 在读取 HTTP 前关闭、回环不受限制、取消后两地址可重新 bind；另验收第二地址端口占用时回滚首个绑定。内部 `ListenerConfiguration(testLoopbackAddress:...)` 只供 `@testable` 测试使用，macOS 用 ::1、Linux 分支用 127.0.0.2，生产初始化继续拒绝这些地址。Linux 分支尚未在本次运行。
- 实际管理 socket 覆盖 LAN HTTP、HTTPS origin 与回环 HTTP 的登录、Host/Origin 拒绝、CSRF、登出和撤销；单元测试逐字节比较两种原有 cookie header。
- Playwright 以合成私有 HTTP origin 连接真实 Swift 管理 API，检查非 Secure/HttpOnly/Strict cookie、登录、创建 Key、重载、跨页风险提示与登出；检查 1440×900 和 390×844，截图仅含合成数据并保存在忽略的 artifacts。Chromium 对 IP 字面量绕过 DNS resolver rules，故用仅转发本机测试服务的有界 HTTP 代理，保留浏览器原始 Host/Origin；未伪造 API 或 set-cookie 响应。这不证明物理局域网路由。Node-only 前端 CI 缺少 ExecutionProbe 时会明确跳过这项集成；本次已构建并实际执行，未跳过。

| 命令 | 实际结果 |
|---|---|
| `swift format lint --strict --recursive Sources Tests Package.swift` | 通过（初次测试函数命名问题已修正） |
| `python3 scripts/check_architecture.py` | 通过 |
| `npm --prefix web run lint` | 通过 |
| `npm --prefix web run format:check` | 通过 |
| `npm --prefix web test` | 30 文件、151 测试通过 |
| `python3 scripts/verify_installation.py` | 静态初始化/Compose config 通过；未创建或构建容器 |
| `python3 scripts/check_docs.py` | 通过 |
| `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` | 完整运行一次通过：319 Swift 测试、33 后端合成脚本，退出码 0 |
| `./scripts/verify.sh --web --chrome` | 完整运行一次通过：151 单元测试、38 Chrome e2e（含 LAN 实际 API） |

开发时还执行了 `swift build --build-tests -j 12`、定向 `swift test --skip-build --filter 'LAN|CookiesStay|HTTPOriginRequires'` / `swift test -j 12 --filter 'LAN|CookiesStay|HTTPOriginRequires|actualAdminSockets'` 的修正后重试，以及 `swift test -j 12 --filter occupiedSecondListener`。初次发现并修正可变数组并发捕获、Darwin 解析器接受 zone ID/前导零、macOS 无 127.0.0.2 alias、共享 quiescing helper 未释放第二 socket，以及测试命名/JSON 解码编译问题；最后定向测试和完整 Swift 测试均通过。

`npm --prefix web run typecheck`、`npm --prefix web run build`、`python3 -m py_compile deploy/init-install.py scripts/verify_installation.py`、`git diff --check` 均通过。`npm --prefix web run test:e2e:chrome -- lan-http` 初次因字面 IP resolver 不生效、旧按钮选择器失败，修正后通过，最终全套 Chrome 再次通过；构建仅有既有 bundle 大小/Vite 配置提示和测试环境提示。

安装器复核另发现 Python `ip_network` 接受点分十进制掩码，而 Runtime 只接受 CIDR 前缀长度；已统一拒绝 netmask/hostmask 写法并增加静态回归，避免安装成功后网关拒绝启动。只重跑受影响的安装静态检查。

无产品契约偏离；来源 CIDR 按提案“收窄”只允许私有/回环子网，并设 64 项配置容量。v0.26.1 发行镜像不含本功能，README 双语明确标为未发布，先使用包含本功能的源码构建或后续发行镜像。

任务 6 留给维护者：记录真实 Codex CLI/Desktop 日期与版本，使用 LAN base_url 分别验收 HTTP/SSE 与 WebSocket 的实际请求、客户端设置接受情况和用量。合成 socket、代理浏览器与安装静态检查不证明真实客户端兼容、真实账号可生成或 Linux/Docker 安装可用；不因此勾选任务 6。

## 相关文档

[文档导航](../../README.md)
