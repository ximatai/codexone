# 托管 Key 配置与本机管理

此切片在一个受控上游上管理多个主体/Key。它不提供账号 OAuth/池、订阅余额或浏览器会话；阶段进度只见 [STATUS](../../STATUS.md)。权限、用量和管理契约见 I12、U12、A10。

## 配置与升级

原单身份配置保持可用。启用托管 Key 时，在私有 `CODEXONE_IDENTITY_CONFIG` JSON 设置 `managedKeys: true`，并移除 `principal`、`keyID`、`keySHA256`；其他上游/模型/价格字段沿用[单身份配置](single-identity.md)。混用两种认证方式拒绝启动；托管模式不回退到旧 Key。

同时设置 `CODEXONE_ADMIN_TOKEN_FILE`，指向独立私有常规文件：当前用户所有、其他用户不可读写、无符号链接，内容为 32—512 字节高熵 ASCII Bearer。文件最多 16 KiB，值不能使用数据 Key 的 `co1_` 格式，也不能与 legacy Key 相同。使用安全随机工具自行生成并私密保存，勿写入仓库、命令行参数或浏览器存储。`--check-config` 校验两种配置/凭证，不建库、不调用上游、不显示路径或秘密。

空数据目录初始化 schema v2。已有 v1 先停服，在原数据目录配置下运行：

```sh
codexone --migrate
```

命令持同一实例锁；先产生 `core.sqlite.pre-v2-<随机标识>.sqlite` 私有一致性备份，再事务升级。保留备份并遵守维护/恢复流程，不能用文件复制遗漏 WAL。失败的 `.partial` 文件不算有效备份；不自动覆盖、删除旧备份。已有 v2 重复命令不降级。升级过程不恢复 intent，由下次普通启动处理。备份机制依据 [SQLite Backup API](https://www.sqlite.org/backup.html)。

## 管理命令契约

仅 loopback 管理端口；请求使用独立管理员 `Authorization: Bearer …`，不接受数据 Key。请求应由本机管理客户端发出，不带 Cookie、Origin、Sec-Fetch-Site；此入口不允许跨源调用，也不构成浏览器登录。不要将真实认证头写入 shell 历史或公开诊断。

| 请求 | JSON / 返回 |
|---|---|
| `POST /api/keys` | 输入 `principal`、`models`、`limits`；返回 `key` 元数据及一次性 `secret`，201 |
| `GET /api/keys?after=<id>` | `after` 可省略；返回 `keys` 与 `nextCursor`，每页最多 64 |
| `PUT /api/keys/<id>` | 输入 `revision`、`enabled`、`models`、`limits`；返回最新 `key`，200 |
| `POST /api/keys/<id>/rotate` | 输入 `revision`；返回同 ID/主体、递增 revision 的 `key` 和一次性 `secret`，201 |

`principal` 为稳定非秘密标识，1—64 字节 ASCII 字母/数字/点/横线/下划线；不能在已有 Key 上改主体。`models` 为 1—32 个不重复的明确模型 ID（每项 ≤128 UTF-8 字节）；有效目录/执行取与上游配置交集，无交集返回空目录。此切片仅文本/客户端工具；图片权限和账号池另交付，不因创建 Key 自动获得尚未支持的能力。

`limits` 必须显式提供五个正整数（≤10¹²）：`requests`（UTC 日请求）、`active`（在途 turn）、`unresolved`（未完整结算执行）、`budgetMicros`（UTC 日估算费用）、`unresolvedMicros`（跨窗口未结暴露）。仍受全局/主体/身份限制。预热/压缩也计入请求；缺用量不记零。轮换不重置计数，禁用不抹除未结暴露。

元数据为 `id/principal/revision/enabled/models/limits/createdAtUnixSeconds`，时间是 UTC Unix 秒；不返回摘要或旧 secret。权限变更和轮换需使用最新 revision，冲突为 409。创建/轮换响应丢失时，先查询元数据，再显式轮换，不能读取已丢失的原文。普通禁用停止下一执行，已准入执行继续结算；原生 WS 每 turn 查当前权限。紧急撤销、管理浏览器登录和完整用量报表仍须对应切片验收。

真实无凭证 SQLite/socket 检查：

```sh
./scripts/verify.sh --backend
python3 scripts/verify_keys.py --binary .build/debug/codexone
```

使用私有临时状态和公开合成管理员凭证，数据 Key 仅在测试内存中生成/使用。覆盖独立认证、Origin/Cookie 拒绝、同主体轮换/跨主体拒绝、已连 WS 撤销、限额与重启、迁移和 DB/WAL/输出无原文；不代表 Desktop、真实账号、浏览器管理界面或生产部署验收。
