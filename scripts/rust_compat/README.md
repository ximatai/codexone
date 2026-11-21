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
