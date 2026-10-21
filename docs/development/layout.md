# 目录与依赖约定

```text
AGENTS.md / README.md / STATUS.md / HANDOFF.md
Sources/                 后端逻辑模块，首个切片再确定 Swift targets
  CodexOne/              进程组装与入口
  Domain/                身份、策略、状态和值类型
  Application/           执行/管理用例和事务边界
  Protocol/              有界解析、事件/对象/usage 分类
  Transport/             NIO 生命周期、HTTP/WS、背压
  Upstream/              订阅适配器、身份/凭证协议
  Persistence/           事务、账本、归属、缓存库
  ControlPlane/          Vapor API、安全会话
  Runtime/               启动恢复、监督、最终化、关闭
Tests/                   Unit / Integration / Contract / EndToEnd / Fixtures
web/                     独立前端包，待正式初始化
  src/                   React/TS 源码
  tests/                 管理流程、类型和 UI 验证
deploy/                  OCI/Compose/反代模板，尚未实现
scripts/                 文档检查，后续构建与测试入口
.github/                 贡献说明；CI 待首个可执行包后引入
docs/                    产品、规范、架构、ADR、变更与证据
```

这些是逻辑目录，不强制九个库 target 或跨进程服务。M1 只激活所需模块，不给空目录补假实现。

Domain 不依赖框架；Application 依赖 Domain 及外部 I/O 端口；Protocol/Upstream/Transport/Persistence 实现边界；ControlPlane 经应用用例读写；Runtime/入口组装依赖，不把全部热路径串行在全局 actor。UI 通过管理 API，不直读 DB。

测试 fixture 不得含凭证或真实用户正文；合成消息可公开。源码注释解释不变量和取舍，不重复代码。文件随能力增长拆分，拒绝按未来扩展预建大量协议。

Package.swift、Package.resolved、web/package.json 和包锁尚不存在；创建时记录实际版本、命令和 Linux 支持范围，禁止照搬实验 lock 后声称生产兼容。
