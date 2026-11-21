# Rust 后端兼容性对照

从仓库根目录构建当前 Rust 网关和固定的 Swift 归档参考。需要 Swift 6.4、Rust 和 Python 3。浅克隆缺少提交时，先执行 `git fetch origin refs/heads/archive/swift-v0.26.53`。

```sh
SWIFT_BASELINE="$(mktemp -d)"
git worktree add --detach "$SWIFT_BASELINE" 65624e4c45ee1f86560b7640abe42bec31a25f60
swift build --package-path "$SWIFT_BASELINE" --product codexone
cargo build --locked --manifest-path rust/gateway/Cargo.toml --bin codexone
python3 scripts/rust_compat/compare.py \
  --reference "$SWIFT_BASELINE/.build/debug/codexone" \
  --candidate rust/gateway/target/debug/codexone
```

下文的 Swift 对照沿用同一个 `SWIFT_BASELINE`。全部跑完后可以执行 `git worktree remove "$SWIFT_BASELINE"`。驱动使用 Python 3 标准库和回环合成上游。两个后端均须支持 `--check-config`、单身份环境变量配置、端口 `0` 和启动输出 `LISTENING data/admin 127.0.0.1:<port>`，其中 `data` 和 `admin` 各占一行。

每种运行方式各用私有临时目录、独立 SQLite 库和回环上游。驱动检查配置校验没有建库或触发上游，然后采集数据和管理入口的健康响应。首轮 HTTP JSON Responses 完成后正常停机，再由同一个后端或另一后端打开同一个库，用首轮响应 ID 发起续接。驱动覆盖 Swift 与 Rust 各自重启、Swift 切到 Rust、Rust 切到 Swift，逐轮核对上游调用次数、SQLite schema 版本、持久结算状态和用量。每次停机后才以只读方式查询数据库。

一致时退出 `0` 并在 stdout 输出公共 JSON 快照。采集结果不同时退出 `1`，在 stderr 输出以 `reference` 为基准的差异。任一运行方式无法完成探测时退出 `2` 并标注该方式。比较忽略 JSON 对象字段顺序，保留数组顺序。响应 ID 由每次单独启动的合成上游确定，快照省略监听端口和进程日志。

Rust 的就绪故障场景使用同一套合成数据和临时端口。它验证磁盘保留空间缺失时两端口均保持存活、就绪返回 503 且生成请求未派发，重启补充保留空间后恢复生成，并验证已核对但仍处于冻结窗口的恢复快照报告执行库未就绪。

```sh
python3 scripts/rust_compat/readiness.py --binary rust/gateway/target/debug/codexone
```

## 执行账本重启恢复

从仓库根目录运行。可在 Rust 后端 CI 构建正式网关后直接运行同一命令。

```sh
cargo build --locked --manifest-path rust/gateway/Cargo.toml --bin codexone
python3 scripts/rust_compat/execution_recovery.py --binary rust/gateway/target/debug/codexone
```

驱动在独立临时目录使用回环合成上游。四个 SIGKILL 场景分别为空闲且未收到请求、上游收到请求但未发首事件、客户端收到 SSE 首事件且账本已有响应绑定、以及请求完成且已持久结算。同库重启后核对 intent 转为 unknown、原始预留及归属、结算证据、SQLite 文件模式和上游调用次数。续接未绑定 ID 应被拒绝，已绑定 ID 可以续接；每个场景只有一条新请求派发并结算。随后用 SIGTERM 正常停机并再次启动，核对账本和派发次数不变。覆盖范围为单身份 HTTP/JSON/SSE 与进程级重启。

## 离线维护互操作

使用上述归档构建 `codexone` 和合成数据探针。在当前工作区构建 Rust 网关，然后运行：

```sh
swift build --package-path "$SWIFT_BASELINE" --product codexone
swift build --package-path "$SWIFT_BASELINE" --product ExecutionProbe
cargo build --locked --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/maintenance.py \
  --swift "$SWIFT_BASELINE/.build/debug/codexone" \
  --probe "$SWIFT_BASELINE/.build/debug/ExecutionProbe" \
  --rust rust/gateway/target/debug/codexone
```

驱动验证实例锁冲突、格式 1 bundle 双向校验和恢复、v18 bundle 恢复升级、代际及 Key 停用、审计幂等、业务日冻结、缺失占用继承，以及 Swift 进程中断后由 Rust 继续重加密。退役检查覆盖保留 bundle、恢复演练与迁移前裸库清单。所有输入均为合成数据，命令使用临时目录。

## 在线备份与并发结算

从仓库根目录运行。驱动构建 Rust CLI 和仅测试用的网关入口，使用私有临时目录、动态回环端口和合成上游。传入上述 Swift 归档编译出的网关可追加跨实现快照验证。

```sh
python3 scripts/rust_compat/online_backup.py
```

测试网关立即开始第一次备份，并在 SQLite 复制完第一批页后暂停。驱动发送一次 HTTP 续接请求，先从源库核对该请求持久结算，再恢复复制。发布后由 Rust CLI 验证快照，并可传入 `--swift` 用 Swift 校验同一份快照。并发请求是否进入快照取决于 SQLite 的快照时点，测试允许该请求处于尚未录入、执行中或已结算状态，若快照包含已结算请求则核对对应的用量和绑定。正式网关仍按首次 10 分钟、每轮结束后 24 小时的间隔运行。

状态与轮转场景使用七份合成旧备份。启动后核对清单恢复和超时提醒，复制中模拟结算储备不足，随后用快照锁触发轮转失败。下次启动释放锁并轮转至七份，核对 HTTP 和 WebSocket 状态一致、手工备份保留及剩余 bundle 均可验证。

## HTTP 正文暂存故障

从仓库根目录运行。临时数据卷需有至少 448 MiB 可用空间，外加 SQLite 运行所需空间。

```sh
cargo build --locked --release --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/http_staging.py --binary rust/gateway/target/release/codexone
```

驱动通过 HTTP/1.1 的 `100 Continue` 确认三个 62 MiB 请求各自取得暂存租约，检查第四个收到 `503 capacity_exhausted`。客户端 TCP reset 后，替补请求可重新取得租约。驱动在其余上传未完成时向网关发送 SIGKILL，核对没有上游调用、没有账本记录，且数据目录没有出现命名暂存文件。重启同一个数据目录后，驱动检查暂存明文字节与 Content-Length、一次结算及三个租约重新可用，并检查进程日志中无合成正文标记或 Bearer Key。

## 用量、存储水位与首页推送

从仓库根目录运行，Swift 使用上述归档。脚本各自使用合成上游、动态回环端口与独立临时数据库。

```sh
swift build --package-path "$SWIFT_BASELINE" --product codexone
cargo build --locked --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/usage.py \
  --reference "$SWIFT_BASELINE/.build/debug/codexone" \
  --candidate rust/gateway/target/debug/codexone
python3 scripts/rust_compat/overview.py --candidate rust/gateway/target/debug/codexone
```

用量驱动对照 Swift v19 的管理响应、浏览器与 Bearer 鉴权和数据入口状态码，并在同一 Rust 进程中核对 WAL 增长、结算预留压力和恢复。首页驱动校验快照顺序、在途首事件及结算更新、握手约束、每会话连接数、登出与关机关闭帧。

## 执行保留与人工释放

从仓库根目录运行。驱动仅启动 Rust 网关，并用合成提供者和临时 v19 数据库验证管理接口与持久账本。

```sh
cargo build --locked --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/retention.py --binary rust/gateway/target/debug/codexone
```

驱动验证 91 天前的明细计入 UTC 日汇总，历史日汇总按现有业务日窗口展示，Key 最近使用保留实际时间。过期绑定、关闭审计和并发样本小批清理，有效绑定与核对期中的未知执行得到保留。人工释放覆盖 Bearer、会话与 CSRF、严格截止边界、旧快照冲突、审计和重启。

## 托管账号 SPA
在 Linux 上给首页驱动传入 `--resources`，采集两次实际 Linux 读数，核对无查看者时的采样、同一份 HTTP/WS 历史、重启清空和关闭实时推送后的 HTTP 读数。历史保留窗口、边界和缺测使用定向 Rust 单测。

使用当前生产 SPA 检查托管账号、额度无观测提醒、已结算用量和同会话撤销。需要 Node.js 26.13.0 和已安装的 Google Chrome。测试从现有托管池 fixture 发起，使用临时 Chrome 配置和合成账号。

```sh
npm --prefix web ci --ignore-scripts --no-audit --no-fund
npm --prefix web run build
CODEXONE_TEST_MANAGED_SPA=1 cargo test --locked --manifest-path rust/gateway/Cargo.toml \
  managed_process::durable_pool_and_governance -- --nocapture
```

## 账号观测、历史和 SPA

Rust 进程测试使用临时 v19 库与动态回环端口，覆盖旧格式趋势回读、分段与抽样、扫描上限、空历史和重启。

```sh
cargo test --locked --manifest-path rust/gateway/Cargo.toml \
  managed_process::account_history_uses_bounded_swift_compatible_reads_after_restart
npm --prefix web run build
cargo test --locked --manifest-path rust/gateway/Cargo.toml --no-run
python3 scripts/verify_account_admin_ui.py --rust --binary "$RUST_GATEWAY_TEST"
```

`RUST_GATEWAY_TEST` 指向 `--no-run` 打印的网关测试可执行文件。该文件启动真实的 Rust 管理与数据监听器，通过测试入口将订阅和 OAuth 地址一起指向同一回环夹具。Chrome 会从 Rust 管理端口加载生产 SPA，使用合成管理员和独立的浏览器上下文。
