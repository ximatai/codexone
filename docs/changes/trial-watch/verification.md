# 验证记录

2026-10-31，macOS arm64，本地合成环境，无 SSH、部署访问、真实订阅调用、Docker/Linux 构建或推送。

| 命令 | 退出码 | 耗时 | 范围 |
|---|---|---|---|
| `swift build --disable-sandbox -j 12 --skip-update --product codexone` | 0 | 79.68 秒 | 本地合成网关可执行文件；既有 Swift 警告未扩大处理 |
| `python3 scripts/verify_trial_watch.py` | 0 | 8.54 秒 | 14 项：正常、失败率 19/20 与 5% 边界、连续就绪失败回滚一次、容器非运行、transport 非零/超时不回滚、既有标记、失败回滚不重试、attention 404/存在、summary 全退出码及行数、凭证/原日志不落地、跨午夜、信号退出、管理数据不可用 |

文档检查 `python3 scripts/check_docs.py`：退出码 0，0.05 秒，199 个 Markdown 文档的本地链接与变更结构通过。

集成用例沿用 verify_admin 隔离启动方式：管理员凭证文件、真实本地网关 HTTP API、`sh -c` 执行经 stdin 输入的固定远端 Python；仅 Docker 命令为合成替身。探测得到 ok，合成上游调用数为 0。另一本地 HTTP 合成用例覆盖 attention 存在与含伪凭证日志的计数/协议名称过滤。

首次构建在完整依赖历史下载缓慢时主动中止（130）；按锁文件相同 tag 在当前 worktree 的忽略目录准备浅克隆后重跑上述构建，未更改依赖版本或锁文件。未验证真实 SSH/服务器、实际 Docker/Nginx 回滚、24 小时耐久、Linux 或真实业务流量；不能据此授权切换。文档入口及边界见 [使用说明](../../development/trial-watch.md)。
