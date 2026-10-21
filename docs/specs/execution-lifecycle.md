# 执行与连接生命周期规范

工作草案。以下状态转移与屏障是实现/测试的行为基线，可按治理流程修订；实现进度只见 STATUS。任务 owner 和依赖组织见 [职责设计](../architecture/ownership.md)。

## E01：执行与提交屏障

核心记录是稳定 principal、API Key、Provider namespace、UpstreamIdentity、CredentialVersion、PolicyVersion、Request、Attempt、Reservation、LedgerEntry、ObjectBinding。连接、lane、网络租约与 actor mailbox 是有限运行态。所有 attempt 在 dispatch 前持久记录身份和执行意图；所有对外可引用 ID 先持久归属，再暴露。

```text
请求：validated -> admitted -> dispatch_intent -> possibly_sent
      -> terminal_observed | confirmed_rejected | indeterminate -> finalized
账本：held -> settled | released | pending_reconciliation
      pending_reconciliation -> settled | released（追加核对/调整记录）
网络：allocated -> connecting -> open -> closing -> released
暴露：none -> unresolved -> resolved（不随网络 released 自动改变）
```

状态分别记录，不能用“客户端已取消”覆盖“上游可能仍执行”。HTTP response head 已提交、语义输出已暴露、上游是否明确接受也是独立事实。没有上游幂等/查询保证时，不可能提供跨数据库与上游 exactly-once；本地只能保证幂等结算与保守识别不确定执行。

### E01-A：屏障 A：准入与 dispatch

一个短事务校验 Key/策略版本、归属、预算与未知暴露阈值，条件扣占预留并插入 request/attempt intent。提交后才可 dispatch；写 intent 前取得本地执行/暴露容量和 finalizer ticket，任何失败释放这些临时资源且不发上游。持久 attempt 的 identity/namespace 不再可变。发送可能开始后即视为 unresolved，只有明确拒绝、可信终态或经审计核对才解除。

### E01-B：屏障 B：ID 归属先于暴露

适配器标注所有允许的可引用 ID 字段。首次含 response ID/文件等可引用对象的完整事件或普通 JSON，先在有界窗口识别并校验 → 事务写入 `(principal, namespace, identity, objectType, rawID, attempt, parent?, expiresAt)` → 提交 → 发布内存索引 → 才允许下游写出包含该 ID 的字节。跨 lane 立即分叉也只能查提交后的绑定。无需每个 delta 写库。

SSE/WS 单事件先缓冲到配置上限再过屏障；普通 Responses/Images JSON 首版有总 body 上限，完整解析与绑定后提交，内存计入全局大响应预算，不写临时正文文件。大 base64 不能无限收集；超限明确失败并结算已发生用量，不能宣称无限图片流式。未来确需更大结果再独立设计增量对象屏障。

绑定写失败则停止暴露本事件，关闭执行并保留 intent/held 供恢复，绝不换账号重放；已向客户端暴露的更早绑定不删除。上游产生了 ID 但本地尚未提交时崩溃，成本可为 pending，而客户端没获得该新 ID；这正是屏障的恢复边界。任何首版无法识别的可引用对象输出应禁止该能力组合，而不是漏绑后继续服务。

### E01-C：屏障 C：最终化单次移交

每个 admitted attempt 预先获得一个 finalizer ticket；进程内 ticket 总数有界，至少覆盖所有可能在途 attempt。连接侧使用原子 `open -> handedOff` 转移一次终态快照；重复完成/取消仅合并证据，不能重复投递结算。finalizer 持独立监督域，不等待 connection actor；网络 reader/writer 关闭也不等待 DB/finalizer。顺序为停止读写与关闭 channel → 移交 ticket → await 网络子任务 → 回收网络租约。避免 writer 等 finalizer、finalizer 又等连接的循环。

handoff 之后的迟到终态/usage 走独立 `mergeEvidence(attemptID, evidenceID, revision)` 路径，不再尝试第二次移交 ticket。每 attempt 预留一个有界证据槽，来源事件用业务唯一键去重；适配器将 cumulative usage 作为更高完整度快照合并，将确需累加的 delta 按序号恰好计入一次。finalizer 未提交时纳入其下一次快照；已提交时追加唯一 adjustment，不能再结算同一 reservation。网络子任务收敛后关闭该本地证据入口，Runtime 的核对结果仍复用同一去重/调整事务；不得因 ticket 已 handedOff 丢掉已观察用量，也不得无界收集迟到事件。DB 失败仍以原 intent/held 恢复 pending，不声称未落盘 usage 已可靠保存。

finalizer mailbox 为每张 ticket 预留终态位置，不以可失败的普通入队作为持久保证；饱和时停止新准入并 drain。数据库失败时 ticket 可保留有限快照直到 deadline，之后释放进程资源并报警，**不依赖再写一次 pending 才可恢复**：已有 held/dispatch_intent 在启动扫描时一律恢复为待核对。不得因丢失 usage 把 held 自动退款。运行中数据库不可写时停止新准入。

结算事务通过 reservation 唯一键与 revision CAS 确保单次状态转换；迟到终态与管理员调整竞争时只允许一个转移，后到证据写追加 adjustment/审计且不重复扣收。账本已结算不代表日志一定送达，非关键统计允许丢弃。

## E02：WebSocket 懒绑定、lane 与取消

```text
handshake_authenticated -> unbound -> binding -> bound(identity, socketGeneration)
                                       \-> closing -> closed
bound -> draining / closing -> closed；同一连接不重新绑定另一个身份
```

握手只认证本地主体、取得连接容量租约，不选择上游账号、不占生成槽。unbound 有首消息期限和全连接待处理字节/条目上限；超时或无合法 create 关闭。第一个经过完整验证的 create 的全部对象引用、模型和工具资格决定身份；连接协调器串行执行 `unbound -> binding`，其他首批 lane 进入有界队列。准入成功并持久记录后固定身份、建立上游 WS；连接失败收敛关闭，不用另一个账号接管同一连接。

若 first create 无额度则按协议发拒绝并保持 unbound（重试仍受速率/首消息期限限制）；有额度但身份/引用冲突明确拒绝。bound 后每个 create 的全部归属必须匹配固定身份；无归属的新 lane 也只能使用该身份。HTTP→WS 与跨连接重连先查询绑定，绝不握手先连“最空闲账号”。空闲 WS 只占连接槽；上游实际连接另受每身份 socket 配额约束，与 active turn 槽分开。

每 socket 单 reader、单帧 writer；reader 按 lane 分派，禁止每 lane 启动共享上游 iterator，禁止每帧创建无界 Task。writer 串行完成帧/分片，不能交错两个消息的片段；发送完成只证明本地写入进展，不证明对端应用已接收。入口在安排 task/actor 消息前取得字节与条目预算，producer 的 stopProducing 对接 channel read 控制，关闭显式触发 continuation 的单次 resume，不靠 deinit。[NIO producer 契约](https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/AsyncSequences/NIOAsyncSequenceProducer.swift)

同 lane command FIFO：接收时做静态能力与大小检查，轮到队首时重查授权并原子准入。队列中的请求不提前占生成额度。若同 lane 前一响应活动中，本地拒绝描述也按 FIFO 排在其终态后输出，避免只有 stream_id 时把错误误归前一 turn。没有容量保存这个拒绝，或未知 lane/畸形控制无法可靠关联时，关闭整个连接，全部活动 turn 独立最终化。跨 lane 可交错，但有全局/Key/身份活动数与单连接总预算。

一个 socket 只有一条读流，不能承诺 lane 网络隔离。高水位暂停整条读取；这会延迟其他 lane 及控制帧，故设置短的总拥塞/下游写 deadline，达到硬上限或期限即关闭整连接，记录 client_too_slow/connection_congested，不惩罚上游账号。控制帧处理只在仍允许读取时前进，不能声称暂停读取后仍有独立 ping 通道。共享拥塞导致未观察终态的 lane 各自进入 unresolved。

warmup 单列：校验全部权限和归属，计入请求速率、每主体 warmup 速率与连接状态数量上限，持有短暂控制槽；无普通生成 token 预留。dispatch 前仍有 durable intent/exposure ticket，观察到适配器定义的 warmup 成功终态后按执行生命周期规范屏障 B 绑定、释放控制槽。无 usage 只有适配器明确保证“不生成/不计生成用量”的模式才可零生成结算；否则保留未知 usage，而不假设免费。warmup 后 create 走正常准入；warmup ID 缓存失效返回状态丢失，不重造历史。

取消由 connection/turn supervisor 拥有：channel inactive、deadline、显式取消都汇入一次 close transition；关闭 channel 中断 socket I/O，task cancellation 中断等待预算/刷新，continuation registry 保证一次 resume。不支持经过验证的 turn 级取消时，关闭整个上游 socket 并明确影响全部活动 lane；本地网络槽释放不证明上游已停止。服务器不生成虚假的 completed。
