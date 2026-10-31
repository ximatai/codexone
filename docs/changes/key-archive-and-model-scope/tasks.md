# 任务

- [x] Core/Adapters：归档标记、archive/unarchive 用例与 API、已归档变更拒绝、列表过滤、keyOptions/attention 处理、审计。
- [x] Core/Adapters：`models`/`imageModels` 可为 null（跟随配置）、目录/准入/策略版本、导入与 `export_key_trial.py`。
- [x] 管理前端：归档/恢复、已归档筛选；模型范围“全部模型/指定模型”编辑与展示。
- [x] 测试；同步 Key 治理、控制面、身份规范、摘要导入与回退说明。
- [x] macOS `verify.sh --backend` 出口（首次失败项及未运行脚本分段补验通过）。
- [x] macOS `verify.sh --web --chrome` 出口（本 worktree 执行，失败类型检查修复后分段补验；主 Agent 后续复核）。
- [ ] Linux verification 出口与部署；上线后将源为“不限模型”的迁移 Key 改为全部模型，归档冒烟测试 Key。

验证详情见 [verification](verification.md)。
