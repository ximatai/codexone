# 项目治理

明确公开状态、行为契约与贡献记录的职责。

## 文档职责

| 位置 | 内容 |
|---|---|
| README / docs 导航 | 定位、最短使用路径与稳定阅读入口 |
| STATUS | 公开版本状态、能力范围、已知限制与路线图 |
| CHANGELOG / Release | 用户可见变化与顶部“升级注意” |
| requirements / reference/specs | 目标和唯一行为契约 |
| architecture / decisions | 模块组织、责任与必要取舍 |
| development / CONTRIBUTING | 构建验证、版本和协作方法 |
| changes | 活动提案、验收任务与相关验证范围 |

STATUS 不保存部署记录、运营数据或逐次验证流水账。任务进度在对应 tasks，实际命令、平台与局限在 PR 或必要的变更验证记录中。完成后将仍有效结论同步规范，删除过程记录，由完整 Git 历史追溯。

## 讨论与变更

产品、规范和决策可依据新证据调整。常规工程选择自主处理；影响外部行为、隐私、用量、schema 或恢复语义时先开 Issue 讨论，建立 proposal/tasks，写明验收和数据/回退影响。文档冲突同步消除，不能留下两份相互矛盾的契约。纯文案/结构调整无需额外提案。

## 质量与维护

PR 聚焦可验收结果，覆盖失败和部分失败，UI 附合成流程与截图。实际运行与模板定义分别说明。发布遵守[版本规则](development/releasing.md)，保留可追溯产物与第三方通知；安全报告、支持版本和响应范围见[SECURITY](../SECURITY.md)。

## 相关文档

[贡献指南](../CONTRIBUTING.md) · [AGENTS](../AGENTS.md) · [变更约定](changes/README.md)
