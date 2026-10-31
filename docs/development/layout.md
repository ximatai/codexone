# 目录与依赖约定

起始组织方案如下；逻辑职责与实际 Swift targets 一起通过垂直功能验证，可据新证据调整，不为维护空树而保留目录。

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
docs/                            产品、规范、架构、共识决策、变更约定
```

四个 Swift 名称对应编译边界；Core/Adapters/Runtime 为库，CodexOne 为入口。Core 不依赖 Vapor/NIO/SQL，Adapters 与 Runtime 分别依赖 Core，入口组装三者。边界类型和 owner 见 [ownership](../architecture/ownership.md)。只有真实需求才拆新 target；测试 target 名与路径对应，Unit/Integration/Contract 为 target 内分组，fixture 按 SwiftPM resources 显式声明。

`CSQLite` 是适配器的系统库桥接，不向 Core 暴露 SQL 类型。`Tests/Support/ExecutionProbe` 是合成子进程故障测试入口，不属于网关公开命令面或发行程序。

Core 内部按 Execution、Identity、Governance、Recovery 等实际业务增长，不先创建完整业务空树。Adapters 的提供者 DTO 不与客户端 DTO 或前端 API DTO 共用，避免大量 optional 变成通用协议包。跨层传小型应用命令和证据，不传 channel/SQL row/Vapor Request。

前端采用 feature 聚合 UI、hooks/API 映射与局部测试；shared 只接收实际复用内容，API 客户端集中遵守管理契约。组件库、生成工具按实际需求选择，不预建横切 services/types 大杂烩。管理契约先明确 ID、时间、用量单位、错误、继承和 secret write-only 字段，并验证同源/代理、CSRF 与会话。

Package.swift、锁文件和前端包配置应记录实际版本及支持范围，不从原型拷贝后宣称产品兼容。构建命令见[验证说明](verification.md)。

前端 `app/` 组装 hash 路由、主题和会话内 Query client；`shared/session` 是唯一管理会话与代际/未知范围锁 owner，`shared/management` 保留同源/CSRF/超时边界。feature 内分离表单/展示与实际复用控制hook，禁止页面重复维护登录。布局样式逐步采用CSS Modules，旧feature样式限定到其作用域，避免全局元素选择器污染Mantine。一次性秘密不进入通用缓存，账号授权流程仍由账号页面持有并在离开时清除。

前端基础层约定：`app/theme.ts` 是 Mantine 主题与静态 CSS 变量的唯一来源；Vite 的 `theme-plugin.ts` 在开发启动和生产构建时生成 `app/generated/theme.css`（忽略的构建产物，由 `main.tsx` 普通 CSS import 引入），同时输出浅色/深色变量。Provider 禁止运行时变量和全局 class 样式注入；当前界面固定浅色。主题生成测试校验主色与两套 scheme，生成目录不参与格式检查。

`shared/query-keys.ts` 集中查询 key；`shared/useManagedMutation.ts` 使用会话 owner 的 CSRF 与生命周期，统一 Query mutation、通知、失效、409 刷新与未知结果锁，不自动重放。查询仅保存可再次读取的公开管理 DTO；修改函数只返回 void，一次性凭证由 feature 局部持有，不进入 Query/Mutation 结果或通知。具体表单与业务校验留在 feature。

`shared/ui/` 放实际展示模式：页头、表格、确认框、状态/错误/空态及时间金额。DataTable 的列定义包含排序值和窄屏标签，响应式使用 CSS Modules 的静态媒体查询。确认框共用 ConfirmModal；所有弹层保留 Mantine 焦点和滚轮/触摸隔离，但关闭会注入 style 标签的滚动条补偿。仅打开时标记 `data-ui-overlay="true"`，由静态 `body:has([data-ui-overlay="true"])` 隐藏背景滚动；关闭后保留的空 root 不得锁住页面。不能为复用组件绕过同源、会话或 CSP 边界。

WorkspaceFrame 用 Mantine 控件与静态 CSS Modules 组织侧栏、顶部操作与小于 768px 的导航 Drawer。Mantine 9.7.3 AppShell 自身无条件渲染 InlineStyles，因此不直接使用该根组件；响应式尺寸禁止传会生成 style 标签的对象属性。图表使用精确同版 `@mantine/charts` 和静态样式 import，缺失数据保留 null，不补造观测。DataTable 支持可选行点击及 Enter/Space 键盘操作，分页与服务端筛选仍由 feature 持有。共享 mutation 的无效输入及业务错误文案由调用方配置；会话、409刷新、不重放和未知结果锁由共享 owner 统一维护。

## 相关文档

[文档导航](../README.md)
