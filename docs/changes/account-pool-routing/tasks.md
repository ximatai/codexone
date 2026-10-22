# 任务

- [x] Core 凭证准备与持久账号快照，SQLite 准入原子复核。
- [x] v4 显式升级/备份/回滚、历史 admission 与失败/竞争验证。
- [x] 有效 access 的 Core 池用例、原子归属交集/最少在途选择与有界 finalizer 所有权。
- [x] 单飞刷新衔接：管理 revision 与路由 credential version 区分、等待者取消、失败不轮流刷新。
- [x] 订阅数据认证的范围复核与生产/合成目标隔离。
- [x] HTTP JSON/SSE/压缩生产装配与真实合成 socket 验收。
- [x] HTTP→WS 桥接与可信认证装配。依旧保留原生连接边界。\n- [ ] WS 身份固定，见后续 WebSocket 变更。
- [ ] 隔离、容量、禁用、取消、未知执行和无重放的真实 socket 验收。
- [ ] 健康/额度观测、按 Key 统计与管理解释。
- [ ] 状态/规范/验证账，阶段提交后 review 与主 Agent 修复复验。
