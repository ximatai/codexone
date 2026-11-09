# 缩短常规 Verify 的关键路径

常规 main 推送按实际提交范围选择检查。范围不明、强制推送、CI 政策变更与未知路径走全量。main 各次推送独立执行，避免后一次取消前一次差异的验证。PR 保留同一 PR 的旧运行取消。

手动 Verify 保留全量。发版前用目标 main 提交的全量 Verify 作证，可与 Release 演练并行。发行仍完整验收优化镜像。后端分片根据实测重排，保持全部脚本各执行一次。

本次仅调整 CI。回退可恢复 main 的全量默认和原分片，无数据迁移。

## 相关文档

[验证约定](../../development/verification.md) · [发版规则](../../development/releasing.md) · [验收任务](tasks.md)
