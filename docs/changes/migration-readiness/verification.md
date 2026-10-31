# 迁移就绪验证

日期：2026-10-31。只使用合成数据与 loopback 提供者，不调用真实账号、不部署、不推送。Linux verification 留给主 Agent。

## Socket 与持久证据

`scripts/verify_migration_readiness.py` 使用真实 HTTP/RFC6455 socket、临时托管 Key 和临时 SQLite；覆盖 HTTP Responses、compact、Images、控制接口、HTTP→WS、原生 WS 的非原生统一标识与原生保持，续接头保留、SDK/门控/凭证剥离。HTTP 400/403/429、截断4xx正文、WS握手4xx、首 error/response.failed 验证 settled/failed、零用量、complete 及可选拒绝标记；5xx、断线、超时、输出后错误及未知码保持 unknown，不重放。

Swift 账号池端到端夹具另覆盖三种HTTP模式的4xx/截断正文、握手拒绝和HTTP/桥接/原生WS首事件拒绝，核对 SQLiteUsageReader 的零费用、零暴露及失败状态。配置单元测试覆盖两种私有格式的边界、原生判定和快照版本选择。

延迟启动合成TCP监听器：第一次连接被拒绝，随后在原期限内建连成功；提供者只收到一次请求。发送后的断线/超时只有一次提供者记录。测试不模拟真实TLS、DNS或代理链路。

## 资源样本

macOS arm64，debug候选、loopback、单次短样本。普通连接上限显式72；64个下游WS各完成一轮后保持对应上游WS，另开8个阻塞compact HTTP，再开4个阻塞控制请求。普通第73个连接得到既有503容量拒绝，控制第5个同Key请求得到429；释放上游屏障后全部在途请求200。每个socket和进程均由夹具关闭并等待。

| 状态 | RSS（KiB） | 文件描述符 |
|---|---:|---:|
| 基线（管理Key已创建） | 22400 | 15 |
| 64个空闲WS及对应上游 | 32560 | 143 |
| 64个空闲WS加8个活动HTTP | 35328 | 159 |

macOS通过系统libproc的PROC_PIDTASKINFO与PROC_PIDLISTFDS只读采样；环境禁止启动ps，未用虚构数据替代。相对基线，64对WS增加10160 KiB和128个描述符；另8对HTTP增加2768 KiB和16个描述符。RSS包含运行时/缓存/SQLite，不等于纯连接对象成本；不外推到release、Linux、真实TLS或1024连接，不据此承诺目标弱宿主容量。

## 验证命令

平台：macOS arm64，Apple Swift 6.4.2，debug候选。下列命令均真实执行并退出0：

| 命令 | 关键结果 |
|---|---|
| `swift build --disable-sandbox` | `Build complete!` |
| `swift test --disable-sandbox 2>&1 \| tail -20`（pipefail） | Swift Testing四target共223项通过（35+41+3+144） |
| `swift format lint --strict --recursive Sources Tests Package.swift` | 无诊断 |
| `python3 scripts/check_docs.py` | 170个Markdown文档及本地链接通过 |
| `CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 全部注册后端脚本通过，包括迁移socket/资源矩阵；代理407仍unknown、提供者400零费用、无效TLS无认证/应用数据、控制60秒超时和取消均通过 |
| `git diff --check` | 无空白错误 |

普通 `swift build` 曾退出1，原因是环境禁止嵌套manifest沙箱（sandbox_apply: Operation not permitted）；按brief改用--disable-sandbox。verify入口及架构检查新增显式CODEXONE_SWIFTPM_DISABLE_SANDBOX=1选项，默认行为不变；Package文件和镜像配置未修改。Linux无网络verification已注册新脚本，但本轮未执行，由主Agent承接；未将其勾选完成。

## 真实验证边界

统一标识后的真实提供者HTTP/Images和WS握手接受情况仍待部署后经授权验证；不从合成成功推导其反爬、版本或风控行为。真实网络10秒建连与退避效果、长期混合负载/目标宿主资源、真实SSE/WS拒绝码形状仍待验证。历史unknown不回填，无schema变更；没有正式迁移或切回操作。

## 主 Agent 复核与真实验证（2026-10-31）

- 本机重跑 `swift build`、`swift test`、`swift format lint --strict`、`check_docs.py` 与 `verify.sh --backend`：退出码均为 0。
- Linux amd64 运行镜像与 `verification` target（含 `verify_migration_readiness.py`）：退出码 0。
- 部署到测试实例（账号池），同时启用公开 API 价格估算。临时 Key 直连网关，客户端标识非原生：
  - 文本请求（`claude-cli` UA，附 `x-stainless-*`）：200，约 3 秒；账本 settled/succeeded，估算费用非零。
  - 原生 Images 生成（`OpenAI/Python` UA）：200，约 34 秒，1 张图片。部署前同类 UA 会被提供者 403 拒绝。
  - 提供者明确拒绝（Images 的 `background` 取非法值）：提供者 400，约 2 秒；账本 settled/failed/`upstream_rejected`，估算费用 0。
  - 提供者会自动纠正非法的 `size` 和 `quality`，这两种情况仍返回 200，不能用来验证拒绝结算。
- 部署后空载时网关容器内存约 26 MiB。
- 未覆盖：非原生客户端经上游 WebSocket 握手的真实请求；原生 Desktop 的 WebSocket 握手由用户日常使用持续观察。
