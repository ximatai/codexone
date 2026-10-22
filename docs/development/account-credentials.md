# 账号凭证层

稳定契约见 [I06/I08/I13](../specs/identity.md)，进度与实际可用入口只见 [STATUS](../../STATUS.md)。此层处理凭证信封和持久刷新责任，公开管理 DTO 不返回原文或信封；上游授权/身份验证、Runtime 单飞和路由属于各自 owner。

## 主密钥与信封

`AccountCredentialCipher.load(path:)` 从独立私有文件读取 64 个十六进制字符，即随机 32 字节 AES 主密钥；文件须由进程用户持有、权限 0600、普通文件且非链接。通过安全随机源生成，不能复用管理员凭证、数据 Key 或把测试夹具常量作为部署密钥。调用者提供绝对路径；可选环境变量 `CODEXONE_ACCOUNT_MASTER_KEY_FILE` 接入生产组装，需同时配置数据目录和独立管理员凭证文件；`--check-config` 加载校验但不打开核心库或调用认证服务。主密钥内容也不得复用管理员 secret（包括同一 hex 的大小写变体）或既有数据 Key 摘要。

信封 `v1.<key-id>.<base64>` 使用随机 96 bit nonce 和 AES-256-GCM。AAD 的有序 UTF-8 JSON 数组依次为固定用途 `codexone.account-credential`、格式 `1`、key ID、identity、namespace、十进制 credential version。key ID 是主密钥 SHA-256 前 16 字节的十六进制；combined 为 nonce + ciphertext + tag。读取按信封 key ID 选择 active/decrypt-only；未知 key ID/格式或不同上下文不能解密。原文 payload 不作为领域类型的 Codable/公开 DTO，诊断字符串固定脱敏。

密钥不进入 SQLite。核心快照包含密文，解密还依赖对应主密钥；分开保护、验证恢复；多版本 active/decrypt-only、离线再加密与旧备份退役检查见[主密钥维护](master-key-maintenance.md)。丢失密钥需要重新授权，不能以新密钥使旧密文自动 ready。

## 应用与事务边界

可信提供者适配器验证稳定身份后，调用 Core `AccountCredentials`：初次 `importVerified` 保持账号 disabled；重新授权必须保持 namespace，通过 revision CAS 递增 credential version。未验证 JWT 的本地声明不能调用“已验证”路径；持久端口不是公开导入 API。

`beginRefresh` 先验证/解密当前版本，再持久刷新 intent，返回的 work 才可交给上游。`finishVerifiedRefresh` 校验同一 namespace，按新版本加密并原子完成；提供者身份不符、密文提交失败或其他不明结果尝试写 auth_uncertain，无法落盘时保留 intent。旧 work 不能重复提交或覆盖新版本。刷新期间更改模式不取消持久责任，完成保留最新 disabled/draining 状态。

SQLite v3 引入的账号/事件与既有执行/Key 在同一核心库；v4 增加 dispatch 准入语义屏障，复用普通有界队列；结束刷新使用 critical 配额。普通审计容量同时计算未完成刷新的一次结束预留，另为全部账号真实禁用预留位置。普通启动在同一事务内恢复执行 unknown 和刷新 auth_uncertain；任一步失败不发布 store。迁移命令不提前恢复状态，流程见 [operations](../specs/operations.md)。

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

## 管理 API

生产入口组装固定 authority provider、初次授权与共享刷新 Service，并把 Core 端口注入 `AccountAdminAPI`；未配置主密钥时不注册账号路由。认证与 body 契约见 A12，具体运行进度见 STATUS。GET/PUT `/api/accounts`、POST refresh 与一次性 authorization 路径复用既有管理 session 或独立 Bearer；浏览器不能混用两种认证。刷新和重新授权不会自动启用初次 disabled 的账号，模式/授权状态需分别核对。

账号 API 本身不创建数据面账号池，enabled 表示管理策略，是否可路由还须通过后续池准入和授权状态复核；不能把列表 ready 当作已有请求执行成功。


## 浏览器操作与合成装配

控制台的“订阅账号”复用管理 session；未配置账号主密钥时提示安全配置尚未开启。初次与重新授权采用 I16 的 code-flow；新窗口完成登录后，将最终回调地址粘贴到隐藏输入，再一次性提交。前端不会自行探测或访问 localhost callback 服务，不保存浏览器本地/会话存储；取消和超时应重新开始流程。未知 mutation 或 CAS 冲突先读列表核对，不能直接重发。

`ExecutionProbe --account-admin-ui` 是测试可执行文件的专用合成组装，生产 codexone 没有该参数或认证地址覆盖。它启动真实管理 API、Runtime owner、AES/SQLite 与显式合成 loopback OAuth。浏览器脚本允许访问临时管理 origin 和合成登录页，拒绝其他地址；只读取合成回调链接而不访问真实 localhost callback 端口。截图输入掩码，日志与 DB/WAL 核对无合成 token/主密钥原文；不替代真实订阅或 Desktop 验收。


## Dispatch 准备与持久快照

`AccountCredentials.prepareDispatch` 读取当前密文并按身份/namespace/version 解密，只返回脱敏诊断的瞬时 work。正常新请求须 enabled/ready，应用已经核实身份续接时才可请求 draining；过期 access 需要既有刷新 owner，不能重复派发。work 不是租约，传输必须把其中非秘密快照交给准入事务（I17），再按持久执行责任发送一次。

当前 v8 不自动升级，已有 v1—v7 须停服显式 migrate，备份保存源版本与未恢复 intent；普通启动才完成 unknown/uncertain 恢复。旧快照恢复的 requires_auth、旧 Key 失效及维护门禁见[快照维护](snapshot-maintenance.md)。旧快照与主密钥依赖仍须一起规划，不能把恢复旧库当作回退期间没有新执行/刷新。

## 订阅账号池的 HTTP 入口配置

`CODEXONE_ACCOUNT_POOL_CONFIG` 指向权限 0600、当前进程所有的私有 JSON，须同时设置数据目录、管理凭证和独立账号主密钥；与 `CODEXONE_IDENTITY_CONFIG` 互斥。配置只接受 `models`、`reservedMicros`、`executionTimeoutSeconds`、`upstreamTransport`，未知根字段拒绝。模型/profile 与单身份配置使用同一校验；目录采用仍要求每个模型的明确非空基础指导。例：

```json
{
  "models": [{
    "id": "example-model",
    "inputMicrosPerMillion": 0,
    "outputMicrosPerMillion": 0,
    "catalog": { "baseInstructions": "Replace with the approved model guidance." }
  }],
  "reservedMicros": 100,
  "executionTimeoutSeconds": 120
}
```

示例模型、指导与价格须替换为管理员确认值；本地价格仅为估算。池只接受数据库托管 Key；创建 Key 的模型选项来自该配置。管理员授权账号后需明确启用；空池、所有账号不可用或 owner 未就绪时 readiness 不能表示可执行。数据请求重新验证 Key，并在原子准入复核当前 Key、选中账号及资源限制。生产认证和数据目标固定，无上游 URL/token/header 配置项。`--check-config` 不建库或发网络请求。

HTTP JSON/SSE 与普通/独立压缩共用既有协议边界。没有可用 access 时至多加入一个共享刷新，未知结果不重放；生成 intent 后也不换账号重发。账号不可用、需要刷新、授权失败或刷新冲突返回安全错误码，不包含提供者正文或账号秘密。原生 WS 的连接身份固定见 P26；Desktop 与真实订阅仍需单独验收。

就绪检查会用当前主密钥和存储 context 本地打开候选密文，错误密钥或全部解密失败返回未就绪。单个结构完整但无法解密的账号不遮蔽其他合格账号；派发也跳过该候选，关键数据库故障仍拒绝。检查不改变授权状态或请求上游，可解密的过期 access 仍由共享刷新处理。

`upstreamTransport` 缺省/`http` 使用 HTTP 上游，`websocket` 为每个 HTTP Responses 请求建立一次选中账号的 WS 上游；对下游仍提供 JSON/SSE。独立 compact 使用同一身份的 HTTP 路径，传输选择进入策略版本但不改变价格版本。选择 websocket 同时启用原生 WS：首 create 原子选账号并建立一次上游连接，所有 lane/后续 turn 固定该身份并逐轮检查权限，刷新不重连。首 turn 结束独立归还执行 ticket；断开、超时及关闭不换账号重放。

账号页面可以展开额度与健康详情并手动读取。额度 GET 与授权刷新使用独立容量；主/次窗口保留提供者时长，五分钟后标陈旧，失败保留最后成功值。禁用账号不周期观察；有效凭证可手动读取，过期须先显式刷新。缺失字段不推算。具体边界见 [U10](../specs/usage.md) 和 [I20](../specs/identity.md)。
