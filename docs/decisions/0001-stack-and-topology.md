# ADR 0001：技术栈与模块化单体

状态：accepted。日期：2026-10-21。

决定：Swift 6 严格并发，窄 NIO 统一数据面，Vapor 管理 API，AHC 上游 HTTP，NIO WebSocket；SQLite 单节点本地持久化；TS/React/Vite 静态管理台；Linux amd64 OCI/Compose、GitHub CI 构建。

依据：原型静默/无响应头断连实验证明要持有 channel 生命周期；Vapor 高层路径不足以承担该数据面。弱服务器与自托管规模优先单体/SQLite，不引入额外服务。前端不需 SEO/SSR，静态 SPA 避免 Node 运行依赖。

代价：自行维护窄传输层；Swift 严格并发不消除重入/事务问题；SQLite 不提供多写 HA。驱动、加密库和 UI 组件在首个相关任务中选择锁版本，不需重开语言框架选型。实验工具链为 6.4，正式最低工具链随包和 Linux CI 固定，不声称验证了新目录。

[架构](../architecture/ARCHITECTURE.md) · [运行规范](../specs/operations.md)
