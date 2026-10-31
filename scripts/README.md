# 脚本入口

脚本需返回真实失败状态、清理子进程并区分 fixture 与显式 live。文档检查不代表产品验收；命令定义见 [verification](../docs/development/verification.md)，可运行入口与结果见 [STATUS](../STATUS.md)。

- [试运行跟踪](../docs/development/trial-watch.md)：`trial_watch.py` 聚合巡检与受控一次性回滚；合成验证入口 `python3 scripts/verify_trial_watch.py`。
