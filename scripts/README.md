# 脚本入口

当前只有 `python3 scripts/check_docs.py`，仅使用 Python 标准库，不访问网络/账号。它检查文档基础，不代表运行时测试。后续脚本必须返回真实失败状态、清理子进程，并区分 fixture 与显式 live。
