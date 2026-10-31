# 验证记录

日期：2026-10-31。平台：macOS 27.2 / arm64，Apple Swift 6.4.2，Node 22.22.0，Python 3.9.6，系统 Chrome。只用合成数据及本机回环提供者，未调用真实订阅、未访问部署实例、未运行 Docker/Linux、未推送。

## 出口与复验

按要求各运行一次总入口；首次失败后继续尚未执行的入口，只重跑失败或后续受改动影响的目标。以下明确保留失败记录，不把分入口成功写成总入口首次成功。

| 命令 / 入口 | 退出码 | 耗时 | 结果 |
|---|---:|---:|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 1 | 2.75 s | 文档/架构通过；长行尾注释未过格式检查，已修复 |
| `swift format lint --strict --recursive Sources Tests Package.swift` | 0 | 8.73 s | 完整格式复验；随后新增查询/回归文件定向格式复验 0 / 0.12 s |
| `swift build --disable-sandbox -j 12` | 0 | 18.68 s | 后端构建；真实 v9 对照构建后重新构建当前产品 0 / 73.27 s |
| `swift test --disable-sandbox --no-parallel -j 12` | 1 | 46.84 s | Core 3、Runtime 43、端到端 44 通过；Adapters 四处旧断言/夹具失败 |
| 同上加 `--filter CodexOneAdaptersTests` | 0 | 59.31 s | 197 tests 全通过 |
| 同上加 `--filter CodexOneRuntimeTests` | 0 | 22.13 s | 43 tests；关停定时等待修复后复验 |
| 路由/大量 unknown 定向回归 | 0 | 23.43 s | 4 tests；只按 intent 索引计算账号并发 |
| 峰值前沿重启/释放回归 | 0 | 17.33 s | 1 test；样本去重、峰值与结束路径 |
| 归档 Key/趋势查询回归 | 0 | 23.00 s | 8 tests；归档前后最近使用、Unix 0 与 null、10 万行查询 |
| 最后保留回归 | 0 | 16.03 s | 2 tests；有效绑定保护 90 天旧执行、到期后清理而不删 unknown、公开日序列端口读取归档 |
| `./scripts/verify.sh --web --chrome`（独立测试端口） | 1 | 15.07 s | lint/格式/类型通过，117 单测通过、Workspace 等待超时 |
| `npm test -- src/app/Workspace.test.tsx`（web 目录） | 0 | 2.94 s | 失败单测定向复验通过，合计 118 单测 |
| `npm --prefix web run build` | 0 | 1.39 s | 生产前端构建通过 |
| `npm --prefix web run test:e2e:chrome`（独立测试端口） | 1 | 29.64 s | 13 通过；三处旧夹具缺少 headroom / 页面等待失败 |
| 同上指定 admin-productization / admin-round2 / overview-phase2 三文件 | 0 | 10.39 s | 三项复验通过，合计 16 Chrome 场景 |
| `npm --prefix web run format:check` | 0 | 0.84 s | 三处测试夹具更新后复验 |
| `python3 scripts/verify_trial_watch.py` | 0 | 8.30 s | 15 tests；80% critical、无额外自动回滚、本机真实管理 HTTP、假 Docker 传输 |
| 实际 v9 二进制迁移 / 拒绝对照 | 0 | 5.76 s | 见下文 |
| `python3 scripts/check_docs.py` | 0 | <1 s | 212 Markdown 文档、链接与变更记录 |

前端经独立 subagent 只读评审；余量刷新/CAS、会话失效与未知图片费用的评审问题已修复。Chrome 交互覆盖核对冲突后刷新、未知用量及原因、保留期文案、1440 大屏和 390 窄屏；截图人工检查通过，无横向溢出。截图与原始构建日志仅留忽略的本地验证产物，不提交。

## 后端集成入口

继续执行 verify.sh 中的全部 33 个 Python 入口，最后全部为 0。下表耗时含启动/清理，合计 472.74 s。协议首次因新增维护任务延后关停失败；改为优雅关停立即取消 timer 并等待已接收事务后，verify_protocol 与 verify_client_protocol 通过。其余未受后续修改影响的成功入口未重复。

所有带 `--binary` 的入口使用隔离保存的本次 v10 产品，ExecutionProbe 同理；随后峰值启动压缩及 Key 最近使用查询的改动另做上表定向验证。

| 入口 | 最终退出码 | 耗时 |
|---|---:|---:|
| verify_storage_pressure.py | 0 | 4.58 s |
| verify_key_maintenance.py | 0 | 1.80 s |
| verify_snapshot_restore.py | 0 | 12.05 s |
| verify_process.py | 0 | 4.48 s |
| verify_execution.py | 0 | 0.24 s |
| verify_accounts.py | 0 | 0.25 s |
| verify_protocol.py | 0 | 7.11 s |
| verify_client_protocol.py | 0 | 16.00 s |
| verify_websocket.py | 0 | 3.49 s |
| verify_protocol_rejections.py | 0 | 1.44 s |
| verify_upstream_proxy.py | 0 | 90.10 s |
| verify_upstream_events.py | 0 | 21.10 s |
| verify_codex_shapes.py | 0 | 7.92 s |
| verify_text_contract.py | 0 | 101.73 s |
| verify_request_parameters.py | 0 | 4.52 s |
| verify_turn_diagnostics.py | 0 | 11.56 s |
| verify_optional_reasoning.py | 0 | 2.47 s |
| verify_context.py | 0 | 3.67 s |
| verify_compaction_stream.py | 0 | 4.95 s |
| verify_images.py | 0 | 58.70 s |
| verify_migration_readiness.py | 0 | 8.84 s |
| verify_control.py | 0 | 62.48 s |
| verify_keys.py | 0 | 15.26 s |
| verify_model_profiles_import.py | 0 | 0.18 s |
| verify_key_export.py | 0 | 0.07 s |
| verify_key_import.py | 0 | 5.50 s |
| verify_trial_provider.py | 0 | 3.89 s |
| verify_lite.py | 0 | 2.30 s |
| verify_admin.py | 0 | 8.22 s |
| verify_admin_round2.py | 0 | 1.57 s |
| verify_admin_assets.py | 0 | 1.68 s |
| verify_pool_config.py | 0 | 2.38 s |
| verify_migration_cutback.py | 0 | 2.21 s |

## 专项证据与迁移风险

- 2000 条 unknown 不阻断准入；全局实际费用超过参考值、每日请求超过参考值仍准入；显式 Key unresolved/预算仍拒绝该 Key；每账号第 17 条返回可重试 429，释放后可再准入。
- 24 小时边界、202 条分批关闭、重启续作/幂等、期内迟到结算、关闭后部分证据不复活占用、完整证据修订、统一 release_unknown 审计与原因分布均通过。
- 质量提醒 10 条/20%、参考值 80%、峰值 13/16、最近 10 分钟 60 条及 7 天同时段中位数 5 倍边界通过；额度高的最近 5 小时前 5 Key 排名保留未知图片费用。
- 保留事务注入删除失败：汇总与删除共同回滚；重启重试成功。在途/核对期内/有效绑定保护、90 天边界、空指标不补零、日汇总计数、绑定到期、blocked 暂停及真实页数下降通过。
- v9→v10 在实例锁下先独立备份，备份可只读打开且仍为 v9；注入 schema 事务失败后版本/列回滚，修复重试成功；auto_vacuum=2；在线备份/恢复 v10 与旧 bundle 兼容验证通过。
- 从本仓库基线 `fea68b10aab938fcb6b916c9558352fec21ecc07` 的产品源码在当前工作区隔离构建真实 v9 二进制。复用 verify_admin_round2.verify_previous：同配置下旧版先正常启动；新版拒绝未迁移旧库；显式迁移备份保留 v9；旧版随后拒绝 v10，数据库摘要不变。没有用伪造版本号冒充旧二进制。
- 一次性 VACUUM 不能包进 schema 事务；失败可能留下已启用的增量回收设置，但旧 schema/备份仍可重试。生产未演练：设有效库大小 D、持续 I/O 吞吐 T，粗估约 4D/T，再加完整性校验/索引/同步时间。1 GiB、50 MiB/s 的纯 I/O 约 82 秒，实际需额外余量；不据小夹具承诺生产秒数。
- 迁移前建议额外可用空间 ≥3D+264 MiB（备份约 D、重写临时库/WAL 约 2D，原库已占空间另计）。空间检查失败保留备份，不自动删备份挤空间；仍需停服窗口及生产备份隔离副本演练。

## 语义更新与承接

旧断言按新契约更新：全局/主体/身份未结与全局请求/预算不再拒绝、账号并发采用 16、人工关闭投影 closed_unknown、恢复核对后的全局缺口只观察。显式 Key/冻结/存储安全限制不放宽；旧版本夹具移除 v10 列表后才降版本，SQL 批量插入补列，迁移/manifest 期望升至 10。监控真实 API 已提供 backup_disabled，测试不再假设提醒接口 404。

30 天滑动续接期是此前未量化期限的新基线，旧绑定获 30 天宽限，需主 Agent 复核；日汇总长期保留，容量受存储水位保护。Linux/Docker 迁移与镜像验证按授权交回主 Agent，当前未声称通过。STATUS.md 按执行授权未修改。
