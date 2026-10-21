# 给下一位 Agent 的交接入口

无需依赖历史聊天。请按以下顺序接手：

1. 读取 [AGENTS](AGENTS.md)，运行 `git status --short --branch`，确认所在目录是正式项目。
2. 读取 [STATUS](STATUS.md)，确定实际阶段与唯一下一步；不要根据空目录误认功能已存在。
3. 读取 [产品范围](docs/requirements/product.md)、[当前架构](docs/architecture/ARCHITECTURE.md)、[规范索引](docs/specs/README.md) 和任务涉及的 ADR。
4. 打开当前变更的 proposal/tasks；如果换能力，先建立相应变更。不要继续旧聊天中未经写入文档的猜测。
5. 先运行 `python3 scripts/check_docs.py`；后续真实 build/test 命令见 [验证约定](docs/development/verification.md)。

## 已定方向

Swift 6/NIO 数据面/Vapor 管理/AHC，SQLite 单节点，React/TS/Vite；订阅账号池优先；图片生成权限独立；兼容治理；首发限期限量加密正文恢复缓存。原始独立设计/评审在 docs/architecture，只作决策过程证据；当前规范和架构是实施入口。

原型参考在 docs/evidence，原型代码未复制。正式项目没有远程、没有运行代码、没有可部署版本。不得访问 Ali 或擅自推送；具体实时状态始终以 STATUS 为准。

## 结束本次工作时

更新 STATUS 和当前变更 tasks/verification，向用户报告以下信息：

- 完成了哪些可观察行为，哪些只是设计。
- 变更文件和关键决策、替代方案及理由。
- 实际执行的验证命令、结果、运行平台与未覆盖场景。
- 未提交的改动、阻塞、下一项明确任务。

不要把正文、凭证、真实图片、完整日志带入交接。进度不在本文件复制维护，保持 STATUS 为唯一入口。
