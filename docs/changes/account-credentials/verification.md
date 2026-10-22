# 验证与复盘

## 2026-10-22 · 加密与持久屏障切片

主 Agent 亲自实现与自我复盘。macOS arm64 / Swift 6.4，只有合成材料，不读取个人授权文件、不调用提供者或真实账号。

`./scripts/verify.sh --backend` 通过：边界、严格格式、构建、60 个 Swift 测试及全部真实进程/协议/Key/session 脚本。新增 8 个测试覆盖 AEAD 随机 nonce、篡改/错误密钥/身份/namespace/version、非法/超量信封、主密钥文件权限/符号链接、刷新 CAS 与并发禁用、密文先改但审计失败时事务回滚、旧 intent 重启变 uncertain、可信身份变化拒绝及重新授权、v2 显式迁移保留 Key。v1 的快照/失败回滚回归继续保留，普通启动不静默升级。

`verify_accounts.py` 纳入统一验证，真实独立进程分别在刷新 intent 前、intent 后和提交后 SIGKILL：重启得到 ready v1、auth_uncertain v1、ready v2；中断刷新不能再开始/迟到完成旧刷新，DB/WAL 不含 token 或主密钥。测试经 Core 用例和实际 Crypto/SQLite，不拿内存 helper 冒充持久屏障；不代表掉电或上游刷新协议。

审计容量自我复盘：仅固定上限会使已开始刷新没有结束位置，或挤占全部账号的禁用。现实现按事件数 + 未完成刷新数计算剩余空间，开始同时预留两条，另有 64 条真实禁用空间。真实库测试将普通边界填满，64 个活动刷新期间全部禁用，重启仍能为全部写入 uncertain；不删除历史或把旧 token 自动 ready。完成刷新保留期间最新模式，不因回调重新启用账号。

尚未接入 Runtime 单飞、提供者身份验证/授权、账号管理界面或账号池数据面，也没有生产主密钥配置入口；这些任务继续保持未完成，不声称完整 M3 验收。该切片 review 与 Linux 结果见下节。

## 2026-10-22 · 独立 review 与修复

bace11b 的 reviewer 实证 P2：域允许合计 32 KiB 的合法 token，其中 `/` 会被默认 JSON 编码为 `\/`，导致超过明文 33000 字节检查，合法刷新结果被不必要地拒绝。主 Agent 仅为凭证 payload 设置 withoutEscapingSlashes，保持 AAD 的既有编码不变；原有信封仍可正常解码。补最大 access/refresh 各 16 KiB 的 slash 密码学往返，以及真实 SQLite/Core 刷新完成后仍 ready、新版本可解密的回归。

修复后 4 个凭证/应用定向测试通过，扩展的真实 SQLite 用例再次单独通过。reviewer 独立完成原提交的 8 个相关 Swift 测试与三个 SIGKILL 场景，未发现其他阻塞问题。98f9746 复审关闭 P2，无新增阻塞；reviewer 独立运行三项定向测试通过，包括最大 slash 与真实 SQLite 刷新。

bace11b 精确快照在 Linux amd64 / Swift 6.4 本地容器完整后端验证通过：60 个 Swift 测试和全部脚本（含三组账号 SIGKILL），exit 0。98f9746 修复快照另在同平台重建后通过 4 个凭证/用例测试及三组真实 SIGKILL，exit 0。均单并发、2 CPU/2500 MiB，本地模拟而非弱服务器/远程 CI；容器正常退出并已回收。修复快照没有重复整个后端，完整结果仅对应原提交，边界回归单独验证。

## 2026-10-22 · Runtime 共享刷新切片

主 Agent 实现 `AccountRefreshSupervisor` 和 Core 端口，未接真实提供者或开放账号 API。`./scripts/verify.sh --backend` 在 macOS arm64 / Swift 6.4 完整通过：66 个 Swift 测试和全部进程/协议脚本。新增 5 个 Runtime 测试覆盖共享刷新的一人/全部等待者取消、64 个立即取消等待者的竞态、身份/全局/每身份等待容量、revision 冲突、并行度、截止期限、父取消、原始提供者错误脱敏及真实 ServiceLifecycle 子服务故障关闭。实际 SQLite 核对未派发队列不写 intent，已派发中断变 uncertain，成功仅提交一次新版本，provider 活动任务归零后 owner 才返回。

自我复盘增加一项持久层修正与第 6 个新增测试：开始刷新使用与执行准入相同的已失败 DB 门。真实事务写故障后去掉故障触发器，库已恢复可写，但受控重启前仍拒绝新刷新 intent，账号元数据不变，不能继续消耗外部令牌。结束写仍保留 critical 配额。关闭时 provider 的取消与停止信号可能同时完成，外部错误统一按 owner 已关闭处理，不把此竞态报告成提供者故障。

资源由 Service 拥有，实际网络端口契约要求响应取消；这些睡眠/取消式合成 provider 测试不证明未来 AHC socket 的关闭、令牌 wire 或真实订阅授权。具体适配、生产组装与账号池仍待后续切片。

e7c200a 独立 review 未发现需修复或阻塞问题。reviewer 核对 waiter install/cancel/enqueue 交错、容量、共享任务停止及关键写入，独立运行 5 个 Runtime 测试与故障 DB 门测试全部通过。该精确 Git 快照在 Linux amd64 / Swift 6.4 本地单并发容器完整后端验证通过：66 个 Swift 测试及全部脚本，exit 0，2 CPU/2500 MiB；容器已回收。未将合成 provider 测试当作真实认证网络验收。

## 2026-10-22 · 可信订阅 HTTP 适配切片

主 Agent 亲自实现与复盘。macOS arm64 / Swift 6.4，`./scripts/verify.sh --backend` 完整通过：73 个 Swift 测试函数及全部进程/协议脚本。新增六个真实 NIO HTTP socket 测试及一项持久状态测试；Runtime 原有用例扩展身份变化失败后不误报存储故障。没有真实账号、个人缓存、外部 token 请求或额度消耗。

实际合成端点验证 PKCE 已知向量/Form 保留字符、ID/access scope 与 nonce/audience/期限、缺省刷新字段、一次持久版本提交、身份变化/畸形/超量/EOF/错误正文/空类型、重定向目的端零请求、四连接容量，以及等待响应头和持续滴流正文均服从总期限。取消与 Service 关闭后真实连接和活动请求归零；测试 server 关闭 pipelining read assistance，确保等待响应期间仍可观察客户端 FIN，不用计数 helper 代替实际关闭。合成与生产 namespace 隔离。

上游明确 invalid_grant 或已知 refresh_token 失效代码且无新 token 时持久化 requires_auth；其余不明失败持久化 auth_uncertain，二者均不能再次自动刷新。真实 SQLite trigger 注入结束审计写失败：保持原 refreshing intent 与旧版本，向调用者报告 storageUnavailable，不能谎报需要重新授权已成功落盘。身份核对已关闭 intent 时，外层重复失败标记的 CAS 冲突不误报存储故障。日志和 DB/WAL 不包含合成明文 token/主密钥。

这是传输/身份验证切片，尚无公开初次授权 owner、账号管理 API/UI、生产主密钥组装或账号池；不宣称真实订阅兼容、生产 TLS、Desktop 或恢复契约已验收。提交后 review 与 Linux 结果待本切片提交后记录。

55502bf 独立 review 未发现需修复或阻塞问题；reviewer 独立运行六个 realOAuth 真实 socket 测试、requires_auth 持久回归及 Runtime 脱敏共八项通过。该精确快照 Linux amd64 / Swift 6.4 本地容器完整后端通过：73 测试和全部脚本，exit 0，单并发、2 CPU/2500 MiB，容器已回收。不是远端 CI、弱服务器或真实订阅验收。

## 2026-10-22 · 初次授权流程 owner 切片

主 Agent 实现 Core 授权端口、Runtime owner 与订阅 adapter 桥接。macOS arm64 / Swift 6.4 完整后端检查通过（77 个 Swift 测试及全部脚本）；随后增加一项实际 socket 贯通测试并重建、全量 Swift 测试 78 项通过。前端未改动，未重复声称浏览器验收。

四组 owner 测试使用真实加密/SQLite，覆盖 session 隔离/错误 owner 不消费、八流程及四并行容量、无效回调先消费且零 POST、单调期限、请求取消/总期限/Service 关闭后活动调用归零、已消费流程不能重放、容量拒绝后仍可继续、创建默认禁用、重新授权 revision CAS/模式保留及 namespace 变化拒绝。第五个贯通用例经真实 HTTP 适配器和合成 NIO socket，用开始流程生成的 nonce 完成验证并加密入库；相同 flow 重放没有第二次 POST。

初次授权代码未开放管理入口，不调用真实认证服务。callback/state/verifier 只在内存传递，公开结果只有登录地址/流程标识和安全账号元数据。提交后 review 待进行；生产组装、账号管理 UI 和账号池未完成。

0be1012 独立 review 无阻塞，reviewer 独立运行四项 owner 测试及实际 socket 贯通共五项通过。主 Agent 采纳非阻塞建议，增强贯通 server：对收到的 verifier 计算 S256 并与开始流程 URL 的 challenge 比对，不再仅检查 verifier 长度。增强后的真实 socket 定向测试重新构建并通过；未改产品行为。

PKCE 增强复审指出 fixture 的可选值比较会把“缺 verifier”和“未设置固定 verifier”的 nil==nil 误当匹配。主 Agent 改为先要求非空 verifier，再显式选择固定 verifier 或 S256 challenge 分支，缺两种期望也拒绝。重建后原始实际 OAuth 刷新链和 owner 贯通两项测试通过。产品实现未受此 fixture 缺口影响。


0be1012 精确快照 Linux amd64 / Swift 6.4 本地单并发容器完整后端 78 测试及全部脚本通过，exit 0；c18f0c9 的 PKCE fixture 修复快照另重建并通过两项实际 socket 测试。均 2 CPU/2500 MiB，本地模拟，非远程 CI/容量，容器已回收。c18f0c9 独立复审关闭 nil 比较缺口，无新增问题。

## 2026-10-22 · 账号 API 与生产组装切片

主 Agent 亲自实现、复盘。macOS arm64 / Swift 6.4，完整 `./scripts/verify.sh --backend` 通过：80 个 Swift 测试与全部脚本。新增一项真实管理 socket 验证：未授权/混合认证/缺 CSRF 拒绝、headless 与浏览器 owner 隔离不消费流程、一次性 code+PKCE 经实际合成 token socket 入库、默认禁用、安全 DTO、模式 CAS 冲突、明确 invalid_grant 持久 requires_auth 后再经公开 API 重新授权，保持原 id/模式并更新版本；登出旧 Cookie 失效。

独立配置测试覆盖主密钥依赖持久存储/管理员、加载实际私有文件、拒绝与管理员 hex 大小写变体或数据 Key 摘要复用。生产进程脚本验证配置成功、权限/格式/复用失败均不创建 check-only 数据库，不打印路径或凭证；组装后的账号空列表与错误 state 一次消费后冲突。此脚本仅产生授权 URL，错误 state 在任何 token POST 前拒绝，不连接真实认证服务。所有成功授权仍由显式合成 loopback 工厂注入；没有新增任意认证地址运行参数。

未改前端，账号 UI 与池路由仍未完成。本切片提交后 review 待进行；不能把生产组装启动或合成授权成功当作真实订阅/额度验收。


d4fb93e 独立 review 无阻塞；reviewer 独立运行三项 Swift 定向测试及完整 verify_admin.py 通过。该精确快照 Linux amd64 / Swift 6.4 本地容器完整后端 80 测试及全部脚本通过，exit 0，单并发、2 CPU/2500 MiB，容器已回收；不是远端 CI/容量。

主 Agent 采纳 review 的 HTTP 断开补证建议：合成 token endpoint 延迟回复，真实管理连接在 POST 已派发且原凭证仍 requires_auth 时关闭；授权 Service 继续收到一次可信响应并原子完成重新授权，管理员之后 GET 看到原 id/模式和 v2 ready，提供者总调用数没有增加。该实际 socket 定向测试重建通过。明确区分 HTTP 断开与 Swift 任务取消，不凭管理连接断开声称回滚；全服务停止仍由 Service 取消并等待在途工作。


22828b1 独立只读复审确认 HTTP 断开证据与契约一致，无新增问题。

## 2026-10-22 · 账号管理界面切片

主 Agent 实现并自我复盘，macOS arm64 / Swift 6.4 / Chrome 155.0.8059.85。`./scripts/verify.sh --backend` 完整通过：80 Swift 测试、全部进程/协议脚本；测试专用 Probe 的新增模式没有改变既有进程/SIGKILL 入口。`./scripts/verify.sh --web --chrome` 通过：类型、生产构建、20 组件/API 测试及 3 概览 Chrome 测试。新增组件/API 用例验证未知写入后只有成功读取才能解锁、失败回调清除且不重发、离开页面忽略迟到结果、范围/分页和意外授权地址拒绝、授权请求期限与安全错误。

`python3 scripts/verify_account_admin_ui.py --binary <ExecutionProbe>` 接生产 SPA/真实 Runtime/管理 socket/合成 OAuth：登录失败与成功、取消流程、打开合成新窗口、PKCE/code 校验后入库、默认禁用、启用、外部更新造成 CAS 冲突、已提交但响应丢失后禁止重复变更、读取失败不解锁、刷新 invalid_grant、同 id 重新授权且保持模式/更新凭证版本，以及登出均通过。成功授权只调用两次合成 token endpoint，另一次合成刷新明确拒绝；脚本断言总数三次，没有自动重放。网络白名单阻止其他浏览地址，未打开真实 localhost callback 服务，无个人浏览配置/真实账号。

`python3 scripts/verify_admin_ui.py --binary <codexone>` 在新构建上重跑既有 Key 操作全流程通过。共享管理请求/session 客户端移入实际复用的 shared 模块，Key 的十秒默认期限保留，账号交换/刷新采用三十五秒客户端期限覆盖服务端三十秒上限。新 UI 的登录/空列表/账号/需要重新授权/重新授权完成 1440×1000 截图保存于忽略目录，主 Agent 已查看账号和失效状态大屏图，未见溢出或遮挡。截图隐藏所有密码输入与授权链接；DOM、local/sessionStorage、日志与真实 DB/WAL 未出现合成凭证/主密钥原文。浏览器初轮因状态文本与操作按钮同单元格造成精确选择不匹配，已将状态独立为 span 后完整重跑通过，不把该初轮失败写成通过。

账号池路由、订阅额度/按 Key 统计、真实订阅及 M2 两项缺口仍未完成。本界面提交后 review 待进行。


## 2026-10-22 · 账号界面 review 与亲自修复

81793c7 的独立 reviewer 重跑 20 前端测试和完整实际 Chrome 流程，查看三张大屏截图；另用真实浏览器复现两项 P2：登出失败后保留账号且重新读取能绕过登出意图恢复写入；其他标签页替换 Cookie 后，本页读取虽成功仍保留旧 CSRF，连续写入 403。

主 Agent 亲自修复：登出开始即清本地账号/证明/提示/flow，未确认时只显示重试；重试读取当前证明，服务端已撤销的 401 也可确认退出。读取账号先同步 session，证明变化清旧 flow，后续 mutation 用新 CSRF；不会用“流程准备好”覆盖已更换 session 的提示。类型/生产构建和 22 前端测试通过。真实 Chrome 全流程扩展并通过：替换 session 后写入失败→重新读取→成功写入，旧 owner flow 清除，以及未提交登出与已提交但响应丢失两种重试；两种未确认状态均没有账号/重新读取/启用入口。提供者仍严格只有三次合成调用，无真实认证访问。

81793c7 精确快照 Linux amd64 / Swift 6.4 本地单并发容器完整后端 80 测试与全部脚本通过，exit 0，2 CPU/2500 MiB，容器已回收。此后仅前端/文档/浏览器脚本修复，不声称 Linux 跑过实际 Chrome UI。修复待提交后复审。


569af49 独立复审关闭两项 P2，无新增阻塞。reviewer 重新运行 22 个前端测试及实际 Chrome 全合成流程通过，包括两类登出重试、session 替换恢复和旧 flow 清除；未修改文件、未访问真实账号。
