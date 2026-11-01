# 空闲配额窗口预热

## 共识与目标

维护者批准每账号默认关闭的合成生成：主 Codex 的 5 小时或一周窗口确定空闲时发送一次最小纯文本请求，同时启动所有空闲窗口。无时间段设置，不使用客户端 Key。遵循 I19/I20、U07/U10、E01—E11、A10—A13；重置卡设置与 v11 迁移已存在，本变更扩展同一个未发布迁移。

## 观察证据与保守判定

现有 wham/usage 适配器读取 rate_limit.primary_window/secondary_window 的 used_percent、limit_window_seconds、reset_at；补充 reset_after_seconds。没有真实订阅验收，字段本身不能证明未启动，因此只承认明确的完整窗口证据：id=codex、时长恰为 18000 或 604800 秒、used_percent=0、reset_after_seconds 等于时长、reset_at 与观察时刻加时长相差不超过 5 秒。任一缺失、未知时长、窗口重复、allowed=false、limit_reached=true 或矛盾都不触发。比例 0% 可能是四舍五入后的活跃值；上述条件缩小误判范围但不能消除此提供者风险。没有 reset 字段不解释为空闲。附加模型窗口不触发。

活跃证据为相同已知时长、未来 reset_at，且已用大于零，或剩余时长严格小于完整窗口减 60 秒；存在 reset_after 时须与 reset_at 一致。观察失败、过期（300 秒）、倒退时钟均不可用于检测或解锁。

## 执行与持久屏障

- 每窗口保存最近尝试时刻、观察 reset_at、等待活跃标记及后来观察到的活跃 reset_at。发送前同一准入事务锁住所有已知空闲窗口并预留审计；任何空闲窗口尚在等待活跃则整次跳过。发送后无论结果都须有晚于尝试的新鲜活跃观察，再等该活跃 reset_at 到期才可再预热；移动的空闲 reset_at 不形成新一轮。重启保留屏障，未知执行不重发。
- 每账号每窗口至少间隔一小时；连续三次失败自动关闭并产生 attention，管理员保存设置可清除停止原因，不能清除窗口屏障。失败包括取消、协议/传输失败及未确认终态；启动遗留 pending 归为 unknown，不自动重放。
- 仅 enabled/ready、无认证健康阻止及所选模型 cooldown、账号未满 16 并发时准入。重新验证账号 revision/凭证版本、设置、观察与模型配置；无可选存储容量时跳过。内部 principal/key 标签为 internal:quota-priming，mode=priming，没有认证材料或客户端 Key。
- 复用 ExecutionCoordinator、HTTPResponseExecution、订阅身份头、配置指纹/代理与正常 HTTP/WS 传输、证据提取、绑定、finalizer 和账本。固定账号，不选池、不失败转移。tools=[]、store=false、仅 user 文本；输出只丢弃，不保存正文。订阅请求契约明确拒绝 max_output_tokens，故不发送该字段；固定最短回答指令、text.verbosity=low、目录声明的最低 reasoning（无声明用 low），不让管理员调整这些参数。
- 模型来自当前配置对话模型；默认按 inputMicrosPerMillion+outputMicrosPerMillion 最低、同价按 ID 的模型（本地估价，不保证真实订阅成本）。保存与发送均验证；配置移除已选模型时持久关闭并提醒，不自动换模型。消息默认 hello，1—200 Unicode 标量，拒绝控制/格式/行段分隔字符，作为纯文本而非 JSON/模板解析。
- Runtime 单顺序 owner，最多一个在途生成，64 条观察提示与 60 秒扫描，无积压 task。20 秒总期限；关闭停止接纳、取消并 await 网络与持久收尾。审计最多 4096 行，含 account/window/model/result/time，不含消息或输出；先占位 unknown，结果原位更新。

## 管理、迁移与回退

GET/PUT /api/accounts/:id/quota-priming 返回状态/设置、配置模型与默认模型，PUT 使用账号 revision CAS；复用管理认证、CSRF/Origin、no-store、8 KiB 和共享容量。UI 显示开关、模型、消息计数、最近结果及合成流量/账号风险提示。

v11 新增每账号状态和独立审计，扩展既有 pre-v11 备份迁移及完整性验证，不建立 v12。备份保留窗口屏障；恢复关闭预热并保留未知责任，账号仍须重新授权。未发布旧 v11 开发库需从 v10 备份迁移或使用新合成库，不静默修改已声明 v11 的库。回退遵循既有 v11 维护指南，保留新账本/未知证据，不能原库降版本。

## 验收与范围

注入时钟、合成 socket/provider/数据库：检测矩阵、两个窗口一次请求、重启屏障、活跃解锁、失败退避/停止、默认关闭、账号状态/容量、配置移除、文本边界、账本/审计、存储失败、取消关闭。管理 API 授权/输入/CAS、前端单元与桌面/窄屏浏览器。最终仅一次 backend wrapper，以及文档、lint、format、web tests；不访问真实订阅、不 SSH、不建 Linux 镜像、不 push/PR。
