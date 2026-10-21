# Agent 接手指南

接手只依赖仓库文件，不需要历史聊天。

1. 读 [AGENTS](AGENTS.md)，检查 `git status --short --branch`。
2. 读 [STATUS](STATUS.md)：实现进度、验证结果、可运行入口、阻塞、远程承接和下一步以此为准。
3. 按任务读 [产品目标](docs/requirements/product.md)、[规范索引](docs/specs/README.md)、[架构](docs/architecture/ARCHITECTURE.md) 和共识决策。
4. 按 STATUS 的下一步核实实际文件；需要行为变更时依治理建立提案/任务。

## 工作原则

业务边界和技术方案可演进；不要把“以前商定”解释为不可讨论。遇到证据不符、实现困难或更好方案，先描述影响和建议，继续不依赖该决定的工作。隐私、用量、恢复与外部兼容语义不能静默改变。

实验材料的适用范围见 [evidence](docs/evidence/README.md)，不得据此推导产品已实现。目录组织与运行责任分别见 [layout](docs/development/layout.md)、[ownership](docs/architecture/ownership.md)。

## 交接输出

更新 STATUS 的当前进度与下一步，任务勾选留在该变更，带日期的验证证据留在 verification。向用户报告改动、实际验证、局限和未提交工作。不在本文件/README 复制当前阶段、完成列表、远程或测试数字。不得将正文/凭证/真实图片作为交接材料。
