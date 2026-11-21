# Rust 后端兼容性对照

从仓库根目录构建基线并自对照：

```sh
swift build --product codexone
python3 scripts/rust_compat/compare.py \
  --reference .build/debug/codexone \
  --candidate .build/debug/codexone
```

后续将 `--candidate` 改成 Rust 后端可执行文件路径。驱动使用 Python 3 标准库和仓库里现有的 HTTP 合成上游。后端须支持 `--check-config`、单身份环境变量配置、端口 `0` 和启动输出 `LISTENING data/admin 127.0.0.1:<port>`，其中 `data` 和 `admin` 各占一行。

两次运行各用私有临时目录、独立 SQLite 库和回环上游。驱动检查配置校验没有建库或触发上游，然后采集数据和管理入口的健康响应。每个后端先完成一轮 HTTP JSON Responses 并正常停机，再打开自己的库，用首轮响应 ID 发起续接。驱动核对上游调用次数、SQLite schema 版本以及每轮的持久结算状态和用量。每次停机后才以只读方式查询数据库。

一致时退出 `0` 并在 stdout 输出公共 JSON 快照；有差异时退出 `1` 并在 stderr 输出带 `reference` 和 `candidate` 标签的 unified diff；任何一侧无法完成探测时退出 `2` 并在 stderr 标注失败侧。比较完整的采集结果，忽略 JSON 对象字段顺序，保留数组顺序。监听端口和进程日志不进入快照，响应 ID 由每次单独启动的合成上游确定。

本场景覆盖单一后端正常停机后的同库续接。双向数据切换、SSE、WebSocket 和异常恢复需用各自的场景验收。
