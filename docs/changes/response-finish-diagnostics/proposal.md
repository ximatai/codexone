# Responses 终态后的传输收尾诊断

以合成 socket 证据区分执行失败和响应完成后的传输收尾。

## 问题与范围

以本地真实网关、loopback 合成提供者和 socket 客户端，区分执行失败与已提交终态后的传输收尾失败。覆盖 HTTP SSE/JSON、HTTP→WS 桥接和原生 WS；不依据路由选择猜测客户端类型，不调用真实提供者。

对应 [P05/P06/P10 与终态提交契约](../../reference/specs/protocol.md)、[执行生命周期](../../reference/specs/execution-lifecycle.md)及[用量](../../reference/specs/usage.md)。先记录原二进制矩阵，只有可复现路径才修改。真实 indeterminate 的状态、错误响应和 warning 必须保持；已完成响应不能追加矛盾的失败结果。

## 验收与选择

矩阵记录客户端收到的状态/事件、attempt state/outcome/usage 及有界日志。检查终态前断开、终态后断开、SSE DONE 前后、上游终态后关闭及正常完成。JSON/WS 无 DONE，对应阶段不适用。检查未知执行、可信 usage 和无自动重放。证据及最终选择见任务与能力规范。

如只复现收尾误报，仅在有明确完成证据的窄边界将其记录为低级别独立事件；如复现追加错误等客户端问题，优先修正该结果。上游关闭的固定原因诊断独立提交，不增加正文、关闭文本或外部标识。

## 合成复现结果

2026-11-03，macOS arm64 / Swift 6.4.2，原始 debug 二进制；本 worktree 的单身份配置与独立字面事件 fixture。全部上游为 loopback，未验证真实客户端、真实账号、账号池选择日志或 Linux。客户端使用 RST，在读取指定边界立即关闭；操作系统调度决定网关是否已经完成下一次写入。终态后与 DONE 前是同一个 SSE 客户端读取边界。下表为 close 模式的初始矩阵，扩展的 keep-alive 与第二取消竞态见后文。

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

没有复现 502/错误事件追加到已成功客户端响应、非主动断开下丢终态或丢可信用量。JSON 的 head/body/end 已是一个 writer sequence；原生 WS 的终态后关闭走自身连接 owner；上游终态后关闭保留已排队终态。直接 HTTP SSE 在这次正常速度矩阵中没有触发迟到写失败，不据此排除其他调度下的相同收尾窗口。初始 close 矩阵未复现 JSON 完成后同一 writer 的第二次写入误报；后续 keep-alive 的新 writer 路径见后文，不将不同 UUID 混为同一执行。

初次采用窄日志分类：`finishStream` 的 DONE/end I/O 抛错标记为收尾失败，统一 fail 保留原有写入与错误 envelope 行为，只将诊断改为独立 info，不带虚假的 502/code，使用固定原因和独立限额。guard 状态错误与执行内失败仍 warning。此复现解释一种与已知现象一致的路径；生产请求未提供传输与关闭证据，无法证明全部生产告警都来自此处，session_account 不能用来判定客户端或传输。

### 扩展竞态与 UUID 对照

首次完整 backend 在新矩阵中发现先前 29 行单次运行未击中的第二条同 UUID 路径，不能据单次通过排除：终态已通过 writer，context 已观察 succeeded；下游 channel closeFuture 使 HTTP supervisor 取消执行任务，执行/进展期限任务组在返回前抛 CancellationError；route 尚未调用 finishStream，外层 fail 的 fallback 同样记录 execution_indeterminate。固定临时跟踪确认 started=true、ended=false、未进入 finishStream、CancellationError=true，SQLite request_id 与 warning 相同。修复只在 writer 成功提交 completed 终态且错误确为 CancellationError 时改用 `execution_cleanup_cancelled`；其余执行内错误保持原日志。跟踪已移除。

keep-alive 还复现不同 UUID 的无 attempt 路径：前一 HTTP 响应已完整结束，读取下一请求时收到 IOError，在尚无 request part 时构造新 writer 并 fail，继而 JSON 写失败，形成两条新的 warning。它不能解释相同 UUID 的 succeeded 组合；没有观察到客户端收到第二个错误结果。仅对此已完成响应后的空闲 I/O/取消，使用 `downstream_idle_read` info、上一响应 UUID，仍保留原有错误写入尝试。新请求已收到 head/部分正文后 reset 的反例继续产生原 warning，不新增 attempt，也不污染上一成功结果；解析错误和首请求失败不在该收尾分类内。

矩阵现在默认同时运行 close 和 keep-alive（原生 WS 不重复），逐条从 SQLite 读取 request_id，将日志标为 `[attempt]` 或 `[no attempt]`，避免将连接错误错配到成功执行。`--keep-alive` 可只运行持久 HTTP；额外反例为 `next-request-reset`。完整验证首次因第二竞态失败后暂停，修复后重复定向压力与全部后端，结果见任务。

### 上游关闭的独立诊断

独立提交仅补充 `upstream_websocket_close` 与 `upstream_websocket_eof`；close 帧只读取头两个字节，日志数字 code 限于 1000—4999，关闭文本不进入日志或 envelope。合成 code 1011 加私有标记的回归验证了这一点。额外 6 行 EOF 矩阵覆盖桥接 SSE/JSON、原生 WS 的终态前/后直接 EOF；终态前维持 F 与原错误，终态后维持 S、无追加错误。此诊断不将正常关闭误记为请求失败，不改重放或结算。

## 数据与回退

无 schema、迁移或配置变化；不更改结算、用量、重试和恢复责任。回退代码恢复旧诊断行为，无数据回退步骤。不得将成功提交 writer 等同于客户端已收到或消费。

## 相关文档

[任务](tasks.md) · [协议规范](../../reference/specs/protocol.md)
