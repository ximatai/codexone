# CodexOne

开源、自托管的 Codex/Responses 账号池与协议网关。后端 Swift 6，数据面 SwiftNIO，管理 API Vapor；前端 TypeScript、React、Vite；单节点 SQLite，Linux amd64 OCI/Compose 首发。许可证 [MIT](LICENSE)。

**当前阶段：正式项目文档与目录基础已建立，尚无产品运行代码。** 本目录不是实验程序的新部署版本，不提供启动命令或可用服务；原型的通过结果不代表本项目已通过验收。

## 开始阅读

1. [AGENTS.md](AGENTS.md)：Agent 必须遵守的边界与工作流程。
2. [STATUS.md](STATUS.md)：当前完成项、未完成项与唯一下一步。
3. [产品范围](docs/requirements/product.md) → [架构](docs/architecture/ARCHITECTURE.md) → [规范目录](docs/specs/README.md)。
4. [HANDOFF.md](HANDOFF.md)：接手顺序、验证与交接模板。

完整目录导航见 [docs/README.md](docs/README.md)，代码位置与依赖方向见 [目录约定](docs/development/layout.md)。

## 首版产品承诺

订阅账号池优先，单管理员域、多账号、多主体/Key 隔离；HTTP/SSE/WS、客户端工具与原生图片生成；请求/并发硬限、兼容优先用量治理；有上限有期限的加密正文恢复缓存；可诊断、备份、恢复、升级与回退。

token/金额不承诺绝对封顶，金额为估算。缓存不保证任意断线无损恢复，也不授权自动重执行模型或工具。首版不建设 SaaS、支付、多实例、通用资产库。

## 本阶段验证

```sh
python3 scripts/check_docs.py
```

该命令仅检查文档基础，不编译服务、不运行协议测试、不访问账号。后端/前端的构建、锁文件及 CI 将在首个实现任务中加入。开发路线见 [roadmap](docs/plans/roadmap.md)。

实验来源为独立仓库 [ximatai/codexone](https://github.com/ximatai/codexone)，证据与适用范围见 [验证基线](docs/evidence/README.md)。本项目远程仓库尚未关联，不能把实验 CI 徽章当成正式项目 CI。
