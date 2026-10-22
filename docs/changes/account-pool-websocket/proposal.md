# 订阅池 WebSocket 身份固定

## 目标与依据

接续账号池 HTTP 切片，按 I02/I04/I05/I08/I18/I19 与 P13/P24 接入 HTTP→WS 桥接和原生 WS。复用既有 frame、lane、上下文/压缩、绑定与证据规则；不建立第二套协议解析器。M2 Desktop/恢复、真实订阅与健康/额度仍各自验收。

私有池配置增加明确的 upstreamTransport：http（默认）或 websocket，其他值仍拒绝；固定生产 origin/可信认证装配不变。传输进入策略摘要，价格摘要不受传输选择影响。HTTP 模式继续拒绝 native WS，websocket 模式提供桥接与原生入口，模型目录/Key 范围不因传输改变。

以桥接和原生连接身份固定构成一个可操作的池 WS 业务闭环，阶段内定向验证，出口集中 review 和完整跨平台检查。池的下游 native 升级只在连接固定身份已接入的 websocket 配置下启用，HTTP 配置继续拒绝。

## 所有权与执行边界

HTTP 桥接在 Core 唯一持久准入之后，使用选中 work 的认证值建立一次上游 WS，再执行一个 turn；握手/传输错误只收尾该 attempt，不重放或换账号。独立 compact 仍用同一身份的 HTTP compact 路径。

原生连接先通过当前 Key 验证，首个 create 通过池用例原子选择/准入，再固定 principal 的 namespace/id。只有该可信身份的访问凭证可建立上游连接；后续所有 lane 都把该连接身份作为 Core 归属交集约束。每个 turn 重新验证 Key、账号模式/授权/凭证版本与资源限额；未知/矛盾引用拒绝，不能因新请求无 previous ID 而重新选其他账号。普通禁用/撤销阻止新 turn，不擦除已准入用量。刷新保持提供者身份等价，连接不会借刷新切换账号；上游拒绝旧握手会话时关闭，不能静默另连重放。

继续由每连接结构化 Task group 拥有一个上游 reader/writer 和 lane workers。首个执行协调器与连接 owner 用容量 1 的双向交接传递首 context/认证值及首 turn 结果：首 turn 完成即归还自己的 finalizer ticket，上游连接寿命由连接 owner 继续监督。不能把首 attempt/ticket 留到整条连接关闭，也不能将 peer 从已结束作用域泄漏为 detached task。首准入失败、握手失败、取消或关闭必须结束交接双方，并等待所有网络任务。

既有 32 连接、16 执行 ticket、33 lane workers、每 lane 4 排队及总消息/字节上限继续生效；交接每连接最多保留一个首 context 和一份认证头，不增加无限缓存/队列。首 turn 与其他命名 lane 可并发，但每个都须独立有持久 intent 和最终化责任。

## 验收

- 新传输配置/策略摘要，以及旧 HTTP 默认和未知覆盖拒绝。
- 真实合成 WS socket 证明首握手账号头来自所选凭证，HTTP 桥接 JSON/SSE、warmup、压缩与后续链可用。
- 同连接默认/命名 lane 固定同账号；同名/跨账号/跨主体引用拒绝，不产生第二账号请求。
- 每 turn 当前 Key/账号检查，禁用/撤销、刷新竞争和未知/部分失败不重放。
- 首 turn 完成后 finalizer 可归零而连接仍可下一 turn；首准入失败、握手失败、静默断开及关闭无失去 owner 的任务/队列。
- 主 Agent 实现、实际验证、自我复盘、提交后 subagent review，再亲自修复复验。完整旧协议回归保留；不以 fixture 或 CLI 代替 Desktop/真实订阅验收。
