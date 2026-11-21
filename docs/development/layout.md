# 目录与包约定

说明 Rust 网关、前端和验证文件的归属。

```text
rust/
  gateway/                       codexone 可执行程序、监听与进程寿命
  execution/                     准入、归属、结算与执行 writer
  account-pool/                  同一准入事务内的候选选择、亲和与健康
  storage/                       SQLite 文件、迁移、实例锁与密钥材料
  governance/                    Key、账号与管理变更
  identity-runtime/              授权、凭证刷新和被动额度观察
  quota-jobs/                    额度窗口预热与重置卡后台任务
  usage/                         用量、活动及只读治理查询
  maintenance/                   备份、恢复与离线维护
  admin/                         管理 HTTP 路由、会话与静态资源
  config/                        启动配置与私有文件校验
  http-upstream/、websocket/     客户端与上游传输
  wire/、responses/              JSON/SSE 编解码及 Responses 语义
  images/、image-service/        图片协议与执行
web/
  src/features/                  按管理能力聚合，shared/ 放已复用内容
  tests/                         跨能力管理流程和浏览器验证
fixtures/                        跨实现或跨前后端的合成契约数据
scripts/                         文档检查、进程级验证和发行工具
deploy/                          镜像、Compose 和 TLS 反代模板
docs/                            规范、架构、指南和变更记录
```

各 Rust crate 维护 Cargo.toml 和 Cargo.lock。目前由 `rust/gateway/Cargo.toml` 构建网关，crate 自身的单元与集成测试分别运行。跨进程脚本使用编译出的网关，有些场景另用从网关测试目标导出的 `RustGatewayProbe`。探针仅用于合成验证。

职责与关闭顺序见[运行边界](../architecture/ownership.md)，构建和测试命令见[验证说明](verification.md)。按实际能力需要拆分 crate，前端按实际复用抽取共享组件。

历史 Swift 目录与构建说明保存在[最后一个 Swift 正式版](https://github.com/ximatai/codexone/tree/65624e4c45ee1f86560b7640abe42bec31a25f60)。

## 相关文档

[文档导航](../README.md)
