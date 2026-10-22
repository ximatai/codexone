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

## 共享刷新寿命

Runtime `AccountRefreshSupervisor` 由入口注入 Core 凭证用例及可信 `AccountRefreshProvider`；自己不依赖加密或 HTTP 框架。Service 必须先运行才接收工作，一次实例停止后不可重新开放。相同 identity/revision 合并等待者，返回相同持久新版本；不同 revision 冲突。身份/等待者/并发和期限见 I14，容量在创建网络任务之前取得。

请求取消只撤销等待；共享任务仍由 Service 负责，结果不保留为无期限结果缓存。Service 停止则通知每个有界工作，尚未派发的队列不开始刷新，运行中的提供者取消并 await。底层 adapter 必须响应取消；截止期限不能强制结束任意忽略取消的 Swift 函数，因此 fake provider 测试不能替代后续真实网络验证。提供者错误被映射为安全刷新错误；不记录私有错误正文。

核心库一旦写失败，开始刷新走与执行准入相同的故障门，不能继续消耗令牌。完成/失败标记仍能尝试关键写入；失败时留下持久 intent，下次启动归纳为 uncertain。该 owner 不负责自动循环刷新 uncertain 或把失败当成可安全重新调用提供者的信号。

## 合成验证

后端统一验证包含密码学/文件/SQLite 测试与 `scripts/verify_accounts.py`。后者控制独立 `ExecutionProbe`：在刷新 intent 前、intent 后及完成后真实 SIGKILL，再打开同一个临时库核对版本/状态、未知刷新不能再次开始、DB/WAL 不含 token 或主密钥。它不连接提供者、不读取个人登录文件，不证明真实刷新协议或账号池可路由；SIGKILL 也不是掉电验收。

## 可信订阅 HTTP 适配

`SubscriptionOAuthProvider` 自身是受监督 Service，启动时创建专用 HTTP client，停止时关闭并等待网络资源。生产 authority 固定；合成 loopback factory 仅供显式依赖注入，其 realm 参与 namespace，不能生成生产 namespace。容量、总期限、响应上限与失败分类见 [I15](../specs/identity.md)。不跟随重定向、不重试连接或刷新，不读取个人登录缓存。

授权码交换使用 PKCE S256 和 Form grant，刷新使用 JSON grant。初次登录核对 nonce、ID audience、issuer、期限，以及 ID/access 的 subject 和订阅 account 一致性。后续刷新必须保持同一 namespace；缺省刷新 token 或 ID token 只能在新 access 已通过身份核对后沿用。这里的声明可信度来自固定 token 端点的直接可信传输，不是 JWT 签名验证器，禁止把任意上传 JWT 交给已验证导入路径。调用者仍须拥有有界、过期、一次性消费的 state/nonce/verifier 流程；本层不提供公开授权入口。

[官方认证说明](https://developers.openai.com/codex/auth)描述 ChatGPT 登录与自动刷新，但不承诺内部 token wire 稳定。此适配仍需真实订阅独立验收；合成测试不消耗真实额度，也不能证明生产 TLS/实际账号兼容。

## 授权流程 owner

`AccountAuthorizationSupervisor` 注入 Core `AccountAuthorizationProvider` 和凭证用例；订阅 adapter 通过协议桥接，不使 Runtime 依赖 HTTP/加密框架。开始返回 flow ID、登录地址和剩余秒数，完成只接受同一 owner 的一次性回调；重新授权另携带账号 id/revision。容量、期限和取消语义见 I16。flow ID 不是认证凭证，必须同时核对管理 owner。

远程部署的最小 code-flow 操作由后续界面引导：在管理员自己的浏览器打开登录地址，再粘贴最终回调地址；本 owner 不在远端占用操作者的 localhost 端口，也不宣称已有 device-flow 支持。公开 API、session 注入及生产主密钥组装仍由后续切片接入，不允许凭测试通过直接触发真实授权。
