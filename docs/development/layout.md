# 目录与依赖约定

起始组织方案如下；逻辑职责与实际 Swift targets 一起通过垂直切片验证，可据新证据调整，不为维护空树而保留目录。

```text
Sources/
  CodexOne/                      可执行入口与组装
  CodexOneCore/
    Domain/                      身份、策略、状态、值类型
    Application/                 执行/管理/恢复用例，外部 I/O 端口
  CodexOneAdapters/
    Downstream/                  客户端 wire 校验/编码
    Transport/                   NIO 生命周期、HTTP/WS、背压
    Upstream/                    提供者 wire、认证、证据提取
    Persistence/                 核心事务与可降级缓存存储
    ControlPlane/                Vapor 管理 DTO/认证/路由
  CodexOneRuntime/                启动恢复、有限任务监督、关闭
Tests/
  CodexOneCoreTests/
  CodexOneAdaptersTests/
  CodexOneRuntimeTests/
  CodexOneEndToEndTests/
web/
  src/                           按账号、Key、用量、恢复等实际能力聚合
  tests/                         跨能力管理流程/浏览器验证
deploy/                          OCI/Compose/反代及发行维护
scripts/                         文档、构建、验证入口
docs/                            产品、规范、架构、ADR、变更、历史证据
```

四个 Swift 名称是初始 target 建议；Core/Adapters/Runtime 为库，CodexOne 为入口。Core 不依赖 Vapor/NIO/SQL，Adapters 与 Runtime 分别依赖 Core，入口组装三者。边界类型和 owner 见 [ownership](../architecture/ownership.md)。只有真实需求才拆新 target；测试 target 名与路径对应，Unit/Integration/Contract 为 target 内分组，fixture 按 SwiftPM resources 显式声明。

Core 内部按 Execution、Identity、Governance、Recovery 等实际业务增长，不先创建完整业务空树。Adapters 的提供者 DTO 不与客户端 DTO 或前端 API DTO 共用，避免大量 optional 变成通用协议包。跨层传小型应用命令和证据，不传 channel/SQL row/Vapor Request。

前端采用 feature 聚合 UI、hooks/API 映射与局部测试；shared 只接收实际复用内容，API 客户端集中遵守管理契约。组件库、生成工具按实际需求选择，不预建横切 services/types 大杂烩。管理契约先明确 ID、时间、用量单位、错误、继承和 secret write-only 字段，并验证同源/代理、CSRF 与会话。

Package.swift、锁文件和前端包配置应记录实际版本及支持范围，不从原型拷贝后宣称产品兼容。可运行命令和实现进度只见 [STATUS](../../STATUS.md)。
