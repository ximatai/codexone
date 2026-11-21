# Rust 后端兼容性对照

从仓库根目录构建基线并自对照：

```sh
swift build --product codexone
python3 scripts/rust_compat/compare.py \
  --reference .build/debug/codexone \
  --candidate .build/debug/codexone
```

后续将 `--candidate` 改成 Rust 后端可执行文件路径。驱动使用 Python 3 标准库和仓库里现有的 HTTP 合成上游。后端须支持 `--check-config`、单身份环境变量配置、端口 `0` 和启动输出 `LISTENING data/admin 127.0.0.1:<port>`，其中 `data` 和 `admin` 各占一行。

每种运行方式各用私有临时目录、独立 SQLite 库和回环上游。驱动检查配置校验没有建库或触发上游，然后采集数据和管理入口的健康响应。首轮 HTTP JSON Responses 完成后正常停机，再由同一个后端或另一后端打开同一个库，用首轮响应 ID 发起续接。驱动覆盖 Swift 与 Rust 各自重启、Swift 切到 Rust、Rust 切到 Swift，逐轮核对上游调用次数、SQLite schema 版本、持久结算状态和用量。每次停机后才以只读方式查询数据库。

一致时退出 `0` 并在 stdout 输出公共 JSON 快照。采集结果不同时退出 `1`，在 stderr 输出以 `reference` 为基准的差异。任一运行方式无法完成探测时退出 `2` 并标注该方式。比较忽略 JSON 对象字段顺序，保留数组顺序。响应 ID 由每次单独启动的合成上游确定，快照省略监听端口和进程日志。

Rust 的就绪故障场景使用同一套合成数据和临时端口。它验证磁盘保留空间缺失时两端口均保持存活、就绪返回 503 且生成请求未派发，重启补充保留空间后恢复生成，并验证已核对但仍处于冻结窗口的恢复快照报告执行库未就绪。

```sh
python3 scripts/rust_compat/readiness.py --binary rust/gateway/target/debug/codexone
```

SSE、WebSocket 和异常退出后的执行恢复另有验证场景。

## 离线维护互操作

使用提案指定的 Swift 兼容基线构建 `codexone` 和合成数据探针。在当前迁移分支构建 Rust 网关，然后运行：

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

从仓库根目录运行。使用提案指定的 Swift 基线。驱动构建 Rust CLI 和仅测试用的网关入口，使用私有临时目录、动态回环端口和合成上游。

```sh
swift build --package-path "$SWIFT_BASELINE" --product codexone
python3 scripts/rust_compat/online_backup.py \
  --swift "$SWIFT_BASELINE/.build/debug/codexone"
```

测试网关立即开始第一次备份，并在 SQLite 复制完第一批页后暂停。驱动发送一次 HTTP 续接请求，先从源库核对该请求持久结算，再恢复复制。发布后，Swift 与 Rust CLI 均验证同一快照，驱动核对已在复制前完成的账本和绑定。并发请求是否进入快照取决于 SQLite 的快照时点，测试允许该请求处于尚未录入、执行中或已结算状态，若快照包含已结算请求则核对对应的用量和绑定。正式网关仍按首次 10 分钟、每轮结束后 24 小时的间隔运行。

## HTTP 正文暂存故障

从仓库根目录运行。临时数据卷需有至少 448 MiB 可用空间，外加 SQLite 运行所需空间。

```sh
cargo build --locked --release --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/http_staging.py --binary rust/gateway/target/release/codexone
```

驱动通过 HTTP/1.1 的 `100 Continue` 确认三个 62 MiB 请求各自取得暂存租约，检查第四个收到 `503 capacity_exhausted`。客户端 TCP reset 后，替补请求可重新取得租约。驱动在其余上传未完成时向网关发送 SIGKILL，核对没有上游调用、没有账本记录，且数据目录没有出现命名暂存文件。重启同一个数据目录后，驱动检查暂存明文字节与 Content-Length、一次结算及三个租约重新可用，并检查进程日志中无合成正文标记或 Bearer Key。

## 用量、存储水位与首页推送

从仓库根目录运行，Swift 使用提案指定的兼容基线。脚本各自使用合成上游、动态回环端口与独立临时数据库。

```sh
swift build --package-path "$SWIFT_BASELINE" --product codexone
cargo build --locked --manifest-path rust/gateway/Cargo.toml
python3 scripts/rust_compat/usage.py \
  --reference "$SWIFT_BASELINE/.build/debug/codexone" \
  --candidate rust/gateway/target/debug/codexone
python3 scripts/rust_compat/overview.py --candidate rust/gateway/target/debug/codexone
```

用量驱动对照 Swift v19 的管理响应、浏览器与 Bearer 鉴权和数据入口状态码，并在同一 Rust 进程中核对 WAL 增长、结算预留压力和恢复。首页驱动校验快照顺序、在途首事件及结算更新、握手约束、每会话连接数、登出与关机关闭帧。

使用当前生产 SPA 检查托管账号、额度无观测提醒、已结算用量和同会话撤销。需要 Node.js 26.13.0 和已安装的 Google Chrome。测试从现有托管池 fixture 发起，使用临时 Chrome 配置和合成账号。

```sh
npm --prefix web ci --ignore-scripts --no-audit --no-fund
npm --prefix web run build
CODEXONE_TEST_MANAGED_SPA=1 cargo test --locked --manifest-path rust/gateway/Cargo.toml \
  managed_process::durable_pool_and_governance -- --nocapture
```
