# 核心代码与测试骨架

## 目标

落实 Core / Adapters / Runtime / 入口四个 Swift targets 与 Swift Testing；NIO 数据入口、Vapor 管理健康 API、有效配置校验与 ServiceLifecycle 监督关闭。建立 React/TS/Vite、Vitest/Testing Library、Playwright 测试入口，统一无凭证验证脚本。

## 范围

仅健康状态与尚未配置的网关能力；未开放的生成入口明确失败，不能假装转发成功。运行默认仅 loopback。通过真实临时端口验证 HTTP、部分启动失败/取消/信号关闭，前端验证 loading/失败/状态展示。

不实现账号授权、路由池、SQLite 账本、图片代理或恢复协议；不访问 Ali/真实上游，不推送。健康 API 不代表网关已 ready，SQLite 驱动随持久执行切片选择。

## 验收与数据

Swift 严格并发编译、四类有意义测试、配置拒绝、进程 SIGTERM 后退出与端口释放；前端类型/构建/组件及浏览器测试。测试使用合成健康契约，无凭证/用户正文/数据库迁移。依赖重新解析并锁定，不搬用原型 lock。
