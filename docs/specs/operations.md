# 持久化与运行规范

- O01：首版必须单节点/单进程、本地可靠磁盘 SQLite，不支持网络共享盘或多写实例；WAL、synchronous=FULL、外键和 busy timeout 必须逐连接初始化/验证。阻塞 DB 工作不得在网络 event loop 执行，不得跨流式持有事务。
- O02：启动必须校验 schema、密钥、实例锁并恢复 intent/pending/exposure/auth_uncertain，再开放对应准入；数据库不可写必须停止新准入。最终化失败不得因 pending 标记没写成功而丢已持久 intent。
- O03：迁移、restore、密钥维护与服务必须共用实例锁；兼容性检查/备份成功后方可迁移。旧快照恢复必须维护态、披露缺失区间、冻结受影响窗口并经审计重建额度基线，不得自动恢复旧余额后 ready。
- O04：备份必须使用一致性方式，验证密钥版本依赖和恢复；核心备份不含恢复正文缓存。回滚必须区分 schema 兼容二进制回滚与旧快照恢复。
- O05：shutdown 必须停止新准入、有界 drain、关闭 channel/移交最终化、await 任务、有限 flush、依次关闭客户端/数据库/event loop。超时未结必须可在启动恢复。
- O06：首发支持 Linux amd64 OCI/Compose；CI 构建镜像，运行时不需要编译器或 Node。ARM/systemd 必须独立验收后才能声明支持；反代须验证 SSE/WS、大小/超时和可信头。
- O07：指标必须低基数，不以 request/Key/response ID 做 label；普通日志不得存正文/图片/秘密。必须观测队列、取消回收、RSS/FD/task、DB/WAL、未知暴露和缓存降级。
- O08：发布必须给源码/镜像可追溯标识、配置契约、升级/备份/回退证据。健康探测不得调用付费模型；账号耗尽不能触发 liveness 重启循环。
