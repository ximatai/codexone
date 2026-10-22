# 账号凭证层

稳定契约见 [I06/I08/I13](../specs/identity.md)，进度与实际可用入口只见 [STATUS](../../STATUS.md)。此层处理凭证信封和持久刷新责任，公开管理 DTO 不返回原文或信封；上游授权/身份验证、Runtime 单飞和路由属于各自 owner。

## 主密钥与信封

`AccountCredentialCipher.load(path:)` 从独立私有文件读取 64 个十六进制字符，即随机 32 字节 AES 主密钥；文件须由进程用户持有、权限 0600、普通文件且非链接。通过安全随机源生成，不能复用管理员凭证、数据 Key 或把测试夹具常量作为部署密钥。调用者提供绝对路径；这里不定义额外 CLI 参数或未经接入的环境变量。

信封 `v1.<key-id>.<base64>` 使用随机 96 bit nonce 和 AES-256-GCM。AAD 的有序 UTF-8 JSON 数组依次为固定用途 `codexone.account-credential`、格式 `1`、key ID、identity、namespace、十进制 credential version。key ID 是主密钥 SHA-256 前 16 字节的十六进制；combined 为 nonce + ciphertext + tag。未知 key ID/格式或不同上下文不能解密。原文 payload 不作为领域类型的 Codable/公开 DTO，诊断字符串固定脱敏。

密钥不进入 SQLite。核心快照包含密文，解密还依赖对应主密钥；分开保护、验证恢复，不直接覆盖主密钥文件或假定支持多版本轮换。丢失密钥需要重新授权，不能以新密钥使旧密文自动 ready。

## 应用与事务边界

可信提供者适配器验证稳定身份后，调用 Core `AccountCredentials`：初次 `importVerified` 保持账号 disabled；重新授权必须保持 namespace，通过 revision CAS 递增 credential version。未验证 JWT 的本地声明不能调用“已验证”路径；持久端口不是公开导入 API。

`beginRefresh` 先验证/解密当前版本，再持久刷新 intent，返回的 work 才可交给上游。`finishVerifiedRefresh` 校验同一 namespace，按新版本加密并原子完成；提供者身份不符、密文提交失败或其他不明结果尝试写 auth_uncertain，无法落盘时保留 intent。旧 work 不能重复提交或覆盖新版本。刷新期间更改模式不取消持久责任，完成保留最新 disabled/draining 状态。

SQLite v3 的账号/事件与既有执行/Key 在同一核心库，复用普通有界队列；结束刷新使用 critical 配额。普通审计容量同时计算未完成刷新的一次结束预留，另为全部账号真实禁用预留位置。普通启动在同一事务内恢复执行 unknown 和刷新 auth_uncertain；任一步失败不发布 store。迁移命令不提前恢复状态，流程见 [operations](../specs/operations.md)。

## 合成验证

后端统一验证包含密码学/文件/SQLite 测试与 `scripts/verify_accounts.py`。后者控制独立 `ExecutionProbe`：在刷新 intent 前、intent 后及完成后真实 SIGKILL，再打开同一个临时库核对版本/状态、未知刷新不能再次开始、DB/WAL 不含 token 或主密钥。它不连接提供者、不读取个人登录文件，不证明真实刷新协议或账号池可路由；SIGKILL 也不是掉电验收。
