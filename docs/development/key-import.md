# 旁路试运行与Key摘要导入

管理员明确批准复用原Key字符串时，可将已核对的SHA-256验证材料导入**全新独立**CodexOne库。无需原文，不直接复制旧表。摘要仍是敏感验证材料，清单须私下保护，不进Git、日志、参数值或管理响应；真实源转换只在源服务器完成。此入口不导入订阅凭证、余额、账号绑定或旧会话。

## 离线清单

停服并设置私有 `CODEXONE_DATA_DIRECTORY`、独立 `CODEXONE_ADMIN_TOKEN_FILE`，然后运行：

```sh
codexone --import-keys /run/codexone/approved-key-import.json
```

文件须当前用户所有的私有普通文件，拒绝软/硬链接、其他用户权限；最多1MiB、1—256条。根严格为version=1、capturedAtUnixSeconds、entries，采集距当前不超过300秒、允许未来偏差60秒。每条严格包含以下字段：

| 字段 | 含义 |
| --- | --- |
| id / principal | 新侧独立稳定标识，1—64 ASCII字母/数字/点/横线/下划线；原则上每个旧Key单独主体，不猜测共享归属 |
| digest | 原始Bearer UTF-8的64位小写SHA-256；与管理员摘要相同拒绝 |
| policy | 显式models/limits；limits 五项均须出现，每项正整数（≤10¹²）或 null（不限）；可含visionInput/imageGeneration/imageModels；同既有Key策略校验 |
| sourceActive | 必须true；源停用条目隔离，不能放入新侧可启用表 |
| sourceExpiresAtUnixSeconds | 必须显式null；带任何过期时间均隔离，当前不支持复制到期语义 |
| policyEquivalent | 必须true；是管理员对转换的明确声明，不是自动证明或免审开关 |

源转换器必须核对模型、强制模型/推理/tier、账号/来源绑定、传输限制及其他旧约束；未知或无法等价/保守表达就隔离，输出单独私有清单与原因，不能只删字段放宽权限。模型权限可缩到已批准测试模型、图片/视觉默认关闭；显式数值模式的新本地限额独立配置，source 模式只保留无任何限额记录的“不限”语义，均不能称继承旧剩余额度。全部清单先核对，只有受支持条目进入导入文件。

源SQLite转换工具为 `scripts/export_key_trial.py --source-db <readonly-source> --approval-file <private-approval> --output-directory <new-private-directory>`。approval严格包含models、limits、selectedName（名称仅私下使用）；工具固定已核对的源列集合，遇新列/未知schema拒绝，只读事务读取Key元数据，不读取账号、正文或凭证表。输出manifest/mapping/quarantine三个独占0600文件及0700目录，终端仅计数；源约束不支持的条目逐条隔离，所选Key不合格则整次拒绝。不能把输出目录的部分文件当作完成导入，任何转换异常先私下核对。

`approval.limits` 可为原有五项显式正整数对象，或字符串 `"source"`。source 模式在同一只读事务中检查 `api_key_limits` 固定列集合（`id, api_key_id, limit_type, limit_window, max_value, current_value, model_filter, reset_at`）；缺表、缺列或新增列均拒绝。源 Key 无任何限额记录时，清单五项均为 `null`；有任何记录则以 `source_limits_unsupported` 隔离，不按模型/时间窗猜测换算。所选 Key 被隔离时整次拒绝。显式数值 approval 行为不变。导入及元数据往返保留 null，仍默认禁用且不清账本/unknown。

## 原子性与启用

整份文件/管理员验证后才打开目标库，持既有实例锁；只接受无Key、Key审计、执行、账号或维护历史且非恢复态的新目标。同事务写全部禁用Key及import_disabled审计，失败整体回滚。输出仅importedKeys/enabledKeys=0。重复导入/已有库/运行实例拒绝，绝不覆盖验证材料或清空旧用量；结果丢失时先查新侧管理元数据，不自动重试覆盖。

启用用既有管理API/界面的revision CAS，首轮只启用明确选择的一枚Key。认证、每turn及持久准入仍走同一Key治理，不增加运行时旧Key回退。轮换会替换原摘要但不清用量，旧字符串在新侧失效；旧服务不自动随之轮换或撤销。两侧用量/额度/撤销均独立，源快照不是持续授权同步。

旧Key停用、带有效期或未知策略的隔离条目不能当作“已兼容”；不允许通过普通启用把未导入条目复活。正式迁移与恢复仍分别遵守[迁移切回](migration-cutback.md)和[快照维护](snapshot-maintenance.md)。

## 合成旁路

使用独立镜像、数据卷、管理凭证、合成上游与loopback端口；客户端入口可先用受控SSH通道；用户明确授权公网接入后，按[TLS反代](tls-proxy.md)增加独立HTTPS数据域，保留原Key、管理端口继续回环，不修改旧服务路由。服务器/连接信息及选定Key映射只保留在私有部署目录，不写本仓库。先检查服务器容量和端口冲突，不复用旧卷或账号refresh token。

`scripts/trial_provider.py --port <private-loopback-port> --model <approved-model>` 是明确的合成fixture：只回固定联通提示，不转发、执行工具、回显或记录输入；支持JSON/SSE、受控上游WS和compact，最多8个连接，HTTP读取10秒、WS空闲300秒，关闭信号中断并等待连接owner。独立容器非root/只读/资源有界，仅配置该fixture地址、无真实上游凭证；这不等于网络防火墙或真实模型能力验证。

客户端首次使用新会话，保留原Key、切换地址，先验目录与固定合成回复，再验实际客户端支持的协议/失败路径。服务部署不代表真实Desktop、订阅或完整容量通过；真实订阅须另行授权并解决独立凭证/账本责任。

验收入口：`python3 scripts/verify_key_import.py --binary <binary>`、`python3 scripts/verify_trial_provider.py --binary <binary>`，及 `python3 scripts/verify_key_export.py`，均纳入完整后端检查。
