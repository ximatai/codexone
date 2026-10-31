# 托管 Key 配置与本机管理

此切片在一个受控上游上管理多个主体/Key，提供独立管理 API 与同源会话。账号 OAuth/池和订阅余额另按其切片实现；阶段进度只见 [STATUS](../../STATUS.md)。权限、用量和管理契约见 I12、U12、A10/A11。

## 配置与升级

原单身份配置保持可用。启用托管 Key 时，在私有 `CODEXONE_IDENTITY_CONFIG` JSON 设置 `managedKeys: true`，并移除 `principal`、`keyID`、`keySHA256`；其他上游/模型/价格字段沿用[单身份配置](single-identity.md)。混用两种认证方式拒绝启动；托管模式不回退到旧 Key。

同时设置 `CODEXONE_ADMIN_TOKEN_FILE`，指向独立私有常规文件：当前用户所有、其他用户不可读写、无符号链接，内容为 32—512 字节高熵 ASCII Bearer。文件最多 16 KiB，值不能使用数据 Key 的 `co1_` 格式，也不能与 legacy Key 相同。使用安全随机工具自行生成并私密保存，勿写入仓库、命令行参数或浏览器存储。`--check-config` 校验两种配置/凭证，不建库、不调用上游、不显示路径或秘密。

空数据目录初始化 schema v9。已有 v1/v2/v3/v4/v5/v6/v7/v8 先停服，在原数据目录配置下运行：

```sh
codexone --migrate
```

命令持同一实例锁；从 v1/v2/v3/v4/v5/v6/v7/v8 升至 v9 时先产生 `core.sqlite.pre-v9-<随机标识>.sqlite` 私有一致性备份，再事务升级。保留备份并遵守维护/恢复流程，不能用文件复制遗漏 WAL。失败的 `.partial` 文件不算有效备份；不自动覆盖、删除旧备份。已有 v9 重复命令不降级。升级过程不恢复 intent，由下次普通启动处理。备份机制依据 [SQLite Backup API](https://www.sqlite.org/backup.html)。

## 管理命令契约

仅 loopback 管理端口；请求使用独立管理员 `Authorization: Bearer …`，不接受数据 Key。请求应由本机管理客户端发出，不带 Cookie、Origin、Sec-Fetch-Site；此入口不允许跨源调用，也不构成浏览器登录。不要将真实认证头写入 shell 历史或公开诊断。

## 浏览器管理

先在 `web` 运行 `npm run build`，把 `CODEXONE_WEB_DIRECTORY` 设置为构建产物目录的绝对路径。例如 `/opt/codexone/web` 只放 index.html 和 assets 内 JS/CSS；不指向状态或凭证目录。启动加载安全快照，文件更新须重启。`--check-config` 也校验静态目录与公开 origin，不打开 DB 或监听端口。

打开实际管理地址，选择“访问密钥”，使用独立管理员文件中的凭证登录。浏览器只在登录正文发送一次原文，以 HttpOnly/Secure/SameSite=Strict Cookie 维持最多 30 分钟的内存会话；不保存到 localStorage/sessionStorage。默认使用 `http://127.0.0.1:<管理端口>`，须用支持 loopback 安全 Cookie 的浏览器。远程反代必须配置 `CODEXONE_ADMIN_PUBLIC_ORIGIN=https://admin.example`，保持同源、转发正确 Host（公开 authority 或实际 loopback authority），不得依赖 X-Forwarded-* 推导来源。HTTP 仅允许 loopback，不修改 Cookie 安全属性。

创建时显式选择模型和本地限额。编辑使用 revision；冲突后核对刷新列表再修改。禁用 Key 可以先轮换并保存新凭证，再显式启用，轮换保持当前启用状态与计数。一次性秘密关闭/离开/登出或五分钟后清除；响应丢失无法找回原文，核对后显式轮换。写入结果未知不会自动重发；登出失败显示待重试，不能据页面已清空推导服务端会话已撤销。

同源会话为 `POST/GET/DELETE /api/session`；变更请求需精确可信 Origin 和 `X-CodexOne-CSRF`，不得混用 Bearer。模型选项为认证后的 `GET /api/keys/options`。服务重启清除所有 session；修改管理员文件后须重启。无管理员配置时仅概览可用，Key 登录明确不可用。

| 请求 | JSON / 返回 |
|---|---|
| `POST /api/keys` | 输入 `principal`、`models`、`limits`；返回 `key` 元数据及一次性 `secret`，201 |
| `GET /api/keys?after=<id>` | `after` 可省略；返回 `keys` 与 `nextCursor`，每页最多 64 |
| `PUT /api/keys/<id>` | 输入 `revision`、`enabled`、`models`、`limits`；返回最新 `key`，200 |
| `POST /api/keys/<id>/rotate` | 输入 `revision`；返回同 ID/主体、递增 revision 的 `key` 和一次性 `secret`，201 |

`principal` 为稳定非秘密标识，1—64 字节 ASCII 字母/数字/点/横线/下划线；不能在已有 Key 上改主体。`models` 为 1—32 个不重复的明确模型 ID（每项 ≤128 UTF-8 字节）；有效目录/执行取与上游配置交集，无交集返回空目录。此切片仅文本/客户端工具；图片权限和账号池另交付，不因创建 Key 自动获得尚未支持的能力。

`limits` 必须显式提供五个字段，每项为正整数（≤10¹²）或 `null`（该 Key 的该维度不限）：`requests`（UTC 日请求）、`active`（在途 turn）、`unresolved`（未完整结算执行）、`budgetMicros`（UTC 日估算费用）、`unresolvedMicros`（跨窗口未结暴露）。缺字段、0、负数、超范围和字符串拒绝；元数据保留显式 `null`，策略版本反映数值/null 变化。准入跳过 null 维度，仍受全局/主体/身份限制及执行容量约束。管理界面每项可选择“不限”，与数值输入互斥；列表、编辑详情和用量页均显示“不限”。预热/压缩也计入请求；缺用量不记零。轮换不重置计数，禁用不抹除未结暴露。

元数据为 `id/principal/revision/enabled/models/limits/createdAtUnixSeconds`，时间是 UTC Unix 秒；不返回摘要或旧 secret。权限变更和轮换需使用最新 revision，冲突为 409。创建/轮换响应丢失时，先查询元数据，再显式轮换，不能读取已丢失的原文。普通禁用停止下一执行，已准入执行继续结算；原生 WS 每 turn 查当前权限。紧急撤销、管理浏览器登录和完整用量报表仍须对应切片验收。

真实无凭证 SQLite/socket 检查：

```sh
./scripts/verify.sh --backend
python3 scripts/verify_keys.py --binary .build/debug/codexone
```

使用私有临时状态和公开合成管理员凭证，数据 Key 仅在测试内存中生成/使用。覆盖独立认证、Origin/Cookie 拒绝、同主体轮换/跨主体拒绝、已连 WS 撤销、限额与重启、迁移和 DB/WAL/输出无原文；不代表 Desktop、真实账号、浏览器管理界面或生产部署验收。

`python3 scripts/verify_admin.py --binary .build/debug/codexone` 验证会话 API、安全头、静态路径及禁用轮换；纳入后端统一验证。构建前后端后，`python3 scripts/verify_admin_ui.py --binary .build/debug/codexone` 用本机 Chrome 的独立临时上下文操作真实 UI/API 与合成上游，截图屏蔽秘密。它不使用个人浏览器状态或真实账号，也不替代 Desktop 验收。纯前端状态/契约测试仍通过统一 web 验证入口运行。

按 Key 的用量与诊断通过管理台访问密钥页面进入，或使用同一管理员认证的 `/api/usage`；查询和估算口径见 [U10](../specs/usage.md)。读取接口不向普通数据 Key 开放。

## 图片与视觉权限

Key 创建/更新可显式设置 `visionInput`、`imageGeneration`、`imageModels`；旧策略缺失字段按关闭处理。`models` 只控制对话模型，`imageModels` 只控制部署映射的公开图片模型。可以发放 `models: []` 的仅图片 Key，但必须启用生成且指定至少一个图片模型。Images generation/edits 共用生成授权；参考图是编辑操作的输入，不要求对话视觉权限。Responses 图片工具同时要求对话模型与图片模型授权。关闭生成不会关闭独立授予的视觉输入。禁用、轮换及 revision CAS 语义保持一致。

管理 options 分别返回 `models` 和 `imageModels`；模型目录只展示 Key 的有效授权交集。新能力不会由旧 Key 自动继承。普通更新请求若省略能力字段按关闭处理；更新方应先读取并原样保留不打算修改的权限。

受控复用原Key字符串的全新目标离线入口见[摘要导入](key-import.md)；默认禁用、显式CAS启用，不向管理HTTP接口提交摘要或旧明文。

## 到期时间

`PUT /api/keys/:id/expiration`提交revision与expiresAtUnixSeconds（正UTC秒，上限10^12；null清除）。允许设过去时间立即阻止新准入，返回新revision。Key列表/创建/轮换/策略更新均含可空expiresAtUnixSeconds；旧编辑接口保留原值。到期返回401 api_key_expired，已派发继续结算，不清零计数。新能力与管理趋势/进行中字段见[管理规范](../specs/control-plane.md)。
