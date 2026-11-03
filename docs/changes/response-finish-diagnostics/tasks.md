# 任务

记录本机合成验证与提交进度。

- [x] 阅读约定、检查干净 worktree，审查 HTTP/桥接/原生 WS 终态与收尾路径。
- [x] 原二进制合成 socket 矩阵；记录客户端、账本和日志，确定是否有客户端错误结果。
- [x] 仅修正有复现证据的路径，添加真实接口回归并同步规范。
- [x] 上游关闭有界原因独立提交：固定 close/EOF 分类及有界数字 code，关闭文本不记录。
- [x] macOS：swift build -j 12、文档检查、定向验证及完整 backend 一次。
- [x] 审查合成数据、差异和提交；报告仍未知的来源及平台限制。

## 已完成的定向证据

2026-11-03，macOS arm64 / Swift 6.4.2：`swift build -j 12`、`python3 scripts/check_docs.py`、37 项脚本分片覆盖检查、修改 Swift 文件格式检查通过。原二进制及修复后二进制各跑完整 29 行矩阵；原生读取超时在 Python 3.9 中单独处理，不等同 socket EOF。额外临时跟踪重复 5 次桥接终态后关闭，均在执行返回后的 DONE 写入失败；跟踪已移除。详细结果和未知范围见提案。

首次完整 backend 在新矩阵发现第二个终态后取消竞态而失败，已据临时类型/边界跟踪及 SQLite UUID 对照扩展修复；另补 keep-alive 空闲读取与下一请求部分正文 reset 的反例。40 次终态后断开压力验证通过（两种上游 × close/keep-alive × 10 次），覆盖 DONE 写失败、执行收尾取消和空闲读取三类 info；4 个部分下一请求反例保持 warning。原二进制与最终修复版的扩展 67 行矩阵均通过（包含 6 行 WS EOF、两种 HTTP 连接模式和部分下一请求反例）；最终完整后端复验已通过，不把本机结果当作 Linux/真实客户端验收。

## 最终验证

2026-11-03，macOS arm64 / Swift 6.4.2：

- `swift build -j 12`：通过，保留仓库已有编译警告。
- `python3 scripts/check_docs.py`、Swift strict format 与架构检查：通过。
- `swift test -j 12 --filter ProtocolFailureDiagnosticsTests`：6 项通过；最终全量运行再次覆盖这些测试。
- 原二进制与修复版的 67 行真实 socket 矩阵、40 次终态后断开压力及 4 个部分下一请求反例：通过。
- 首次 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 在新增矩阵捕获终态后取消竞态而失败；修正该已复现路径后重新完整运行，427 个 Swift 测试、37 项后端脚本全部通过，新增 67 行矩阵亦在该次完整运行中通过。
- `git diff --check`、新增内容与合成数据审查：通过；无版本、发布标题、web、schema、结算或重试修改，无临时跟踪。

均使用当前 worktree 的本地二进制和合成 loopback 服务。未运行 Linux 构建、真实账号/端点、真实客户端或部署验收；无法确认全部生产告警同因，未依据 session_account 推断客户端。客户端 reset 的调度可改变是否触发收尾日志，不能保证每次关闭都击中同一条 await。

## 相关文档

[提案](proposal.md) · [验证约定](../../development/verification.md)
