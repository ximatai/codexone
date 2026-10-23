# 长任务与模型profile验证 · 2026-10-23

实现 `15b33f5`，主Agent修复 `bdbd427`，最终取消/生产导入回归 `0e9f20f`，Linux CLI测试隔离说明 `f0153fe`。两位subagent集中review/复审关闭，无新增P1/P2；主Agent亲自实现、定向测试及出口验证，未进行真实Desktop或订阅调用。

总期限默认600秒（最大1800），首响应30秒、业务进度空闲60秒；HTTP/SSE、桥接/native WS及compact共用验证后的预算。SSE注释/控制帧/重复状态/空delta不续期；JSON受非空正文进度、大小与总期限约束。WS请求空闲不截断正在执行或已排队的turn，连接一小时寿命与容量边界保留。

0600/1MiB离线profile整份校验，只导入已选模型的catalog；完整内联覆盖、原字节摘要/来源/版本/客户端/30天陈旧披露，不导入价格/权限/路由。默认与最大上下文分开，上限2000000而不扩大网络容量。运行实例持加载副本，新启动拒绝坏源。配置不能注入内部provenance，即使null也拒绝。

## 实际执行证据

| 平台 | HTTP单次 | WS→HTTP桥接单次 | 原生WS单次 | socket场景数 |
| --- | --- | --- | --- | --- |
| macOS | 125.271 s | 125.087 s | 125.095 s | 28 |
| Linux | 125.294 s | 125.167 s | 125.275 s | 28 |

每个场景实际启动网关与受控provider，核对SQLite终态和恰好一次上游调用。覆盖正常持续进度、首响应静默、进度停止、SSE注释/WS ping、重复状态、空delta、总期限、收到真实created后客户端取消、compact；HTTP另测JSON半正文停滞。正常长样本settled，超时/取消unknown，上游关闭且handler/任务收尾；没有自动重放或释放未知责任。macOS长样本在最后的native提前close断言收紧前启动；收紧只影响验收守卫，最终脚本另跑28项3秒定向场景，Linux125秒样本使用最终脚本。3秒样本不计长寿命证明。

- macOS arm64：完整后端检查逐项完成（179项Swift及全部后端脚本）。全量在图片stall发现期限竞争后停止；修复后重跑图片HTTP/WS，接续keys/admin/admin_assets/pool_config/migration_cutback，并对最终protocol/context/compaction_stream做相关回归，不重复无关已通过检查。来源注入等最终8项定向Swift通过。架构/格式/文档及差异隐私检查通过。
- Linux amd64：Swift6.4.1优化程序；实际protocol/websocket/compaction_stream/images/pool_config逐项通过。生产pool导入检查有效快照、0644/链接/缺模型/注入/无效预算/坏源，拒绝时无DB和秘密输出。实际CLI0.163.0在两平台三传输从私有快照选模、采用指导、文本/工具/续接、目录来源摘要与预算披露均通过。
- Linux CLI环境限制：最初失败为缺辅助bubblewrap，补齐后Docker禁止非特权userns；失败样本不计协议通过。最终显式使用外层隔离容器沙箱（非root、只读根、禁外网、2CPU/1536MiB/pids128、私有临时状态，无个人资料挂载），输出标记outer-container；不证明内层Linux沙箱。macOS默认read-only回归与容器外拒绝该显式选项通过。未改变服务权限。
- 独立新候选 `codexone:long-task-profile-candidate`：源码 `0e9f20fe7cc804eb3c596d6a58587504366d8016`；镜像ID `sha256:e062d4672233b42ec6a0e960ed244217440ccad2bcfe94a95b50448f5b1f588c`；Linux二进制SHA256 `e7382d6f28bb3f2345dafeeb162e299b8a393d5fbbd1760cd6ff6bb54288f9a5`。镜像二进制与受测程序逐字节一致，归档重新载入保持标识。安装/迁移/重启、默认兼容配置下不同v8同卷回退再升级及Key/unknown保留、实际打包SPA Chrome登录/创建/清除/重读/退出通过，主Agent已查看大屏截图。使用新增配置回退旧程序须同时恢复旧版兼容配置。旧Desktop候选及归档不变，不推送/发布。

忽略目录 `artifacts/long-task-profiles/` 保存两平台长样本报告、最终macOS短回归、源码/镜像归档、二进制标识、截图与摘要清单；报告只含场景/计时/计数/摘要，不含正文、凭证或私有路径。

## Review与排错

修复配置可注入provenance及极端采集时间减法溢出；修复AHC与业务总期限同时到期会抢先返回502，将底层兜底延后5秒，业务总期限不变且图片stall恢复504；取消验收须确认200/真实created，native提前close直接失败。初版monitor睡到首响应旧期限会延迟较短idle，改100ms有界检查。夹具曾漏native mask及给compact加禁止字段，均修正，失败记录不计通过。

限定恢复关联实验见前阶段验证；本闭环不建设生产缓存。M5、真实Desktop/订阅、完整O14与目标宿主仍保留，下一步先讨论Desktop独立配置与操作矩阵。
