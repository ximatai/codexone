# 配置字段参考

索引环境变量、私有账号池文件和模型配置的约束。

## 环境变量

| 字段 | 含义 |
|---|---|
| `CODEXONE_DATA_PORT` / `CODEXONE_ADMIN_PORT` | 默认 18080/18081；0 为临时端口，非零端口不可相同 |
| `CODEXONE_DATA_DIRECTORY` | 核心库绝对目录；生产安装由卷和镜像入口提供 |
| `CODEXONE_ACCOUNT_POOL_CONFIG` | 私有账号池 JSON，与单身份配置互斥 |
| `CODEXONE_IDENTITY_CONFIG` | [受控单身份配置](../development/single-identity.md)，主要用于合成验证 |
| `CODEXONE_ADMIN_TOKEN_FILE` | 独立管理员秘密文件，非数据 Key |
| `CODEXONE_ACCOUNT_MASTER_KEY_FILE` | 独立 32 字节 hex 主密钥或私有 keyring |
| `CODEXONE_LISTEN_ADDRESS` | 空为仅回环；显式私有 IP 增加数据/管理第二监听，范围与拒绝规则见 [O12](specs/operations.md#o12基础进程与健康契约) |
| `CODEXONE_ALLOWED_NETWORKS` | 空为私有网段加回环；可逗号分隔 CIDR 收窄第二监听的来源，最多 64 项 |
| `CODEXONE_ADMIN_PUBLIC_ORIGIN` | 与浏览器地址完全一致的受信 origin |
| `CODEXONE_WEB_DIRECTORY` | 管理 SPA 目录，启动加载安全快照 |
| `CODEXONE_BACKUP_DIRECTORY` | 已存在的私有备份绝对目录；省略则不启用在线备份 |
| `CODEXONE_UPSTREAM_HTTP_PROXY` | 无认证 HTTP CONNECT，空值直连，配置失败不绕过 |

## 账号池 JSON

参考[合成模板](../../deploy/pool.example.json)和[账号配置字段](account-credentials.md)。模型权限、价格和上限分别表达；未知字段拒绝。`modelProfilesFile` 指向已审核离线快照，格式见[模型 profile](model-profiles.md)。`clientFingerprint` 影响上游 Codex 标识，风险见[协议兼容](compatibility.md)。

`dataConnections` 默认 128、范围 8—1024。执行总期限默认 600 秒（1—1800），首响应 30 秒（1—120），进度空闲 60 秒（1—300）；显式阶段值不能超过总期限。`imageConcurrency` 默认 2（1—8）。这些值不是可用吞吐或内存承诺，须结合实际负载验收。

所有秘密文件必须满足对应 owner、普通文件、权限和大小校验。部署时用 `--check-config` 验证；它不建库、不调用认证服务、不证明账号可生成。配置启动后不热重载，修改需维护重启。

## 相关文档

[配置指南](../guide/configuration.md) · [主密钥](../operations/master-key-maintenance.md) · [图片字段](../guide/images.md)
