# M1 验证与自我复盘

2026-10-21，macOS arm64 / Swift 6.4 / 系统 SQLite。

`./scripts/verify.sh --backend` 通过：严格格式、架构边界、构建、22 个 Swift Testing 函数（无效端口含 7 参数案例）、真实网关进程检查及四个 SIGKILL 屏障重启场景。真实库覆盖竞争准入、跨窗口/主体未知预留、绑定前后可见性、主体隔离、完整/部分/缺失用量、重复/冲突/迟到累计证据与超额拒绝、实例锁、未知/未版本化非空 schema、事务失败回滚、SQLite query_only 实际不可写错误。

finalizer 验证：ticket 在准入前取容量、准入失败不 dispatch 并归还、连接取消移交不等待持久写入、满载写入失败时停止准入、无循环等待、关闭 drain 后任务结束；失败 intent 重开成为 unknown。网关配置存储后仍不 ready；第二实例在监听前拒绝且不输出路径，正常关闭后重开。

自我复盘修正：未知金额必须跨窗口占用；DB 接单与入队必须在同一锁内，防止 close 越过已接受命令；过时累计证据不能包含高于新快照的计数；持久失败后即使写入恢复也需显式重启核对才能再准入。新建库权限 0600，默认目录 0700；系统 SQLite 桥接不依赖本机 Homebrew 路径。

范围：仅空库到 v1，无非空 schema 升级；治理配置为合成切片固定配置，不是完整授权/账号管理；无真实上游、Desktop 协议或掉电证据。未执行远端 CI/部署，Linux 验证另行记录。

## 提交后 review 与主 Agent 修复

700e846 的 subagent review 找到四项：历史证据容量会拒收最终用量；操作抛错会丢此前观察用量；数据库默认文件权限可能为 0644；非空未版本化旧库被拒绝前已改 journal 模式。主 Agent 全部修复并同步规范：累计证据以 (attempt, revision) 标识，独立保留最新真相、最近 128 条历史及持久压缩水位；水位以内旧证据明确 staleEvidence，worker 不因已过时最终化停服。执行上下文保留单个有界可信快照，失败也移交，移交后封闭本地观察入口。兼容检查先于 journal 修改，校验 v1 表结构；DB/lock/WAL/SHM 原子安全创建或收紧为 0600，拒绝不安全文件类型/归属/硬链接。

2026-10-21 主 Agent 再次运行 `./scripts/verify.sh --backend` 全通过，26 个 Swift 测试函数。新增 128 partial → 第 129 complete → 更高迟到用量、压缩水位重开/重复/冲突、观察 complete/partial 后取消仍入账、过时最终化不停止 worker、拒绝旧库前后字节一致；进程验证在 umask 022 与既有 0755 目录检查 DB/lock/WAL/SHM 为 0600，并验证旧 0644 文件重开收紧。初始“新建库0600”的描述在首次 review 时尚未成立，以本次实际权限回归为准。

6590ce7 复审确认四项修复有效；reviewer 实际运行 7 个相关 Swift 回归、网关进程/权限与四个 SIGKILL 场景通过。另发现空库识别中的 SQL LIKE 下划线通配符会错误忽略 `sqlitex` 用户表。主 Agent 改为字面下划线的 GLOB 模式；`swift test -j 4 --filter rejectedLegacySchemaDoesNotMutateDatabaseContentsOrJournal` 的 legacy/sqlitex 两个参数案例均通过，拒绝前后数据库字节不变。

5e2aea5 最终复审：reviewer 重跑 legacy/sqlitex 两例通过，五项可操作问题全部关闭，本机合成执行/真实 SQLite/进程故障范围可进入 M2。Linux amd64 验证仍在进行，未将其或真实客户端计入完成证据。

## Linux 独立验证

2026-10-22，Docker Desktop 本地 Linux amd64（arm64 宿主上的模拟执行），Swift 6.4 noble 镜像，独立源码快照 8184adb 与 Linux 构建目录。首次 2 并发在约 2.8 GiB Docker VM 中 OOM 终止；重试为单并发、2 CPU、2500 MiB 容器限制，`CODEXONE_BUILD_JOBS=1 ./scripts/verify.sh --backend` 全通过：架构/格式/构建、26 个 Swift 测试函数、网关实际 HTTP/锁/信号/权限/关闭重开，以及四个 SIGKILL 屏障恢复场景。

这是独立 Linux 构建/运行证据，不是远端 GitHub CI、弱服务器混合容量或主机掉电验收。未调整 Docker 全局设置、未访问用户服务器或真实账号。
