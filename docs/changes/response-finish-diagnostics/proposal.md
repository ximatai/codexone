# Responses 终态后的传输收尾诊断

以合成 socket 证据区分执行失败和响应完成后的传输收尾。

## 问题与范围

以本地真实网关、loopback 合成提供者和 socket 客户端，区分执行失败与已提交终态后的传输收尾失败。覆盖 HTTP SSE/JSON、HTTP→WS 桥接和原生 WS；不依据路由选择猜测客户端类型，不调用真实提供者。

对应 [P05/P06/P10 与终态提交契约](../../reference/specs/protocol.md)、[执行生命周期](../../reference/specs/execution-lifecycle.md)及[用量](../../reference/specs/usage.md)。先记录原二进制矩阵，只有可复现路径才修改。真实 indeterminate 的状态、错误响应和 warning 必须保持；已完成响应不能追加矛盾的失败结果。

## 验收与选择

矩阵记录客户端收到的状态/事件、attempt state/outcome/usage 及有界日志。检查终态前断开、终态后断开、SSE DONE 前后、上游终态后关闭及正常完成。JSON/WS 无 DONE，对应阶段不适用。检查未知执行、可信 usage 和无自动重放。证据及最终选择见任务与能力规范。

如只复现收尾误报，仅在有明确完成证据的窄边界将其记录为低级别独立事件；如复现追加错误等客户端问题，优先修正该结果。上游关闭的固定原因诊断独立提交，不增加正文、关闭文本或外部标识。

## 合成复现结果

2026-11-03，macOS arm64 / Swift 6.4.2，原始 debug 二进制；本 worktree 的单身份配置与独立字面事件 fixture。全部上游为 loopback，未验证真实客户端、真实账号、账号池选择日志或 Linux。客户端使用 RST，在读取指定边界立即关闭；操作系统调度决定网关是否已经完成下一次写入。终态后与 DONE 前是同一个 SSE 客户端读取边界。

符号：S = settled/succeeded/complete；U = unknown/cancelled/无用量；C = settled/cancelled/complete；F = unknown/failed/无用量；W = warning `execution_indeterminate` / status 502。每次仅一个 attempt / 一次上游派发，无重放。

| 客户端边界/上游动作 | HTTP→HTTP SSE | HTTP→HTTP JSON | HTTP→WS SSE | HTTP→WS JSON | 原生 WS |
| --- | --- | --- | --- | --- | --- |
| 正常 | 200，completed + DONE；S；无日志 | 200 completed；S；无日志 | 200，completed + DONE；S；无日志 | 200 completed；S；无日志 | completed，连接保持；S；无日志 |
| 客户端终态前关闭 | 收到 created；U；W | 无响应；U；W，另有 downstream_json_write | 收到 created；U；W | 无响应；U；W，另有 downstream_json_write | 收到 created；C；无日志 |
| 客户端读取终态后关闭 | 200 completed；S；无日志 | 200 completed；S；无日志 | 200 completed；S；W | 200 completed；S；无日志 | completed；S；无日志 |
| 客户端读取 DONE 前关闭 | 同终态后 | 不适用 | 同终态后 | 不适用 | 不适用 |
| 客户端读取 DONE 后关闭 | 200 completed + DONE；S；无日志 | 不适用 | 200 completed + DONE；S；无日志 | 不适用 | 不适用 |
| 上游终态后立即关闭 | 200 completed + DONE；S；无日志 | 200 completed；S；无日志 | 200 completed + DONE；S；无日志 | 200 completed；S；无日志 | completed 后正常关闭；S；无日志 |
| 上游终态前关闭 | 200，已有事件后 error；F；W | 502 error；F；W | 200，已有事件后 error；F；W | 502 error；F；W | 已有事件后 status 502 error；F；W |

矩阵脚本：`python3 scripts/verify_response_finish.py --binary .build/debug/codexone`。`--baseline` 仅跳过修复后日志断言，便于对原二进制重验；`--route`、`--case`、`--repeat` 可缩小/重复边界。每个成功窗口检查返回用量和唯一终态；终态前上游关闭检查错误响应及 unknown 无用量；原生下游断连有界续读保留 usage，同时结果保持 cancelled。

### 精确路径与客户端影响

原二进制的 HTTP→WS SSE 终态后关闭复现该 warning。临时固定跟踪在相同路径连续 5 次确认：`HTTPResponseExecution.execute` 已返回 → `route` 调 `finishStream` → `[DONE]` body 写入抛错（未到 HTTP end）→ `serve` 的 catch 调 `writer.fail` → `protocolFailure` 的未知错误 fallback → `protocolErrorEnvelope` 记录 warning。此前 `observeSubmittedTerminal` 已观察成功，核心 owner 的 defer 已移交可信用量与 outcome，故账本为 S。临时跟踪已移除，不进入产品。

没有复现 502/错误事件追加到已成功客户端响应、非主动断开下丢终态或丢可信用量。JSON 的 head/body/end 已是一个 writer sequence；原生 WS 的终态后关闭走自身连接 owner；上游终态后关闭保留已排队终态。直接 HTTP SSE 在这次正常速度矩阵中没有触发迟到写失败，不据此排除其他调度下的相同收尾窗口。未复现 JSON 完成后第二次写入的误报，也不据猜测修改该路径。

采用窄日志分类：仅 `finishStream` 的 DONE/end I/O 抛错标记为收尾失败，统一 fail 保留原有写入与错误 envelope 行为，只将诊断改为独立 info，不带虚假的 502/code，使用固定原因和独立限额。guard 状态错误与执行内失败仍 warning。此复现解释一种与已知现象一致的路径；生产请求未提供传输与关闭证据，无法证明全部生产告警都来自此处，session_account 不能用来判定客户端或传输。

## 数据与回退

无 schema、迁移或配置变化；不更改结算、用量、重试和恢复责任。回退代码恢复旧诊断行为，无数据回退步骤。不得将成功提交 writer 等同于客户端已收到或消费。

## 相关文档

[任务](tasks.md) · [协议规范](../../reference/specs/protocol.md)
