# 协议对齐验证

记录合成提供者与本地传输验证的范围，不替代真实订阅账号兼容结论。

## 当前业务边界

共享正文预算由 48 MiB 放宽到 64 MiB，单正文仍为 32 MiB。GIF/SVG 默认沿图片启用与有效模型授权，不再有逐账号确认字段；普通 SVG 使用上游默认编写模型。当前固定开源 Codex 工具未暴露独立 SVG 编写模型，显式非 null svg 对象在派发前拒绝；这不是对所有 Desktop 版本的运行结论。

## 本地证据

2026-11-05，macOS arm64、Swift 6.4.2：

- 全量 Swift 测试 471 项通过（Core 7、Runtime 67、EndToEnd 88、Adapters 309）。包括两个最大正文同时占用 64 MiB、第三个等待释放、队满/超时/取消、WS 断连及溢出恢复、图片权限/模型范围、默认 GIF/SVG、独立 SVG 模型拒绝与关键重复参数检测。
- `verify_images.py` HTTP/websocket 配置矩阵通过：无额外配置的 GIF/SVG、普通模型与 Key 权限拒绝、重复参数无派发、畸形/空/错误/混合输出和媒体类型失配拒绝、可信用量保留，以及两路 32 MiB 占满后排队上传与断连释放。另对 svg_usage 独立编写用量保留 partial/unknown，避免仅凭图片计数完整结算。
- `verify_upstream_ws_body_limit.py` responses/codex-subscription 真实套接字矩阵通过：两路最大正文占满预算时 WS 仅发大帧头等待，释放后继续成功；现有 1009/413、断流、不重放与账本责任保持。
- `measure_upstream_ws_body_limit.py` 的独立进程、fake provider、约 20 ms ps RSS 采样：17 MiB 单请求峰值约 99.80 MiB，32 MiB 单请求约 169.97 MiB，两路 32 MiB 约 285.36 MiB；空闲约 20.8 MiB。仅网关 RSS，排除 Python 客户端/提供者；不是 Linux 容器容量证明。
- 严格格式、文档、架构边界及 44 个脚本分片覆盖检查通过。只读复核确认移除格式门槛未绕过现有图片权限，响应与重复参数保护仍在。

## 再次复盘发现的覆盖缺口

2026-11-05 两名 subagent 只读复盘并由主代理核对代码：

- Responses 图片工具允许 GIF/SVG 请求，但其完成结果经 imageResult 使用参考图的 ImagePayload 校验，只接受 PNG/JPEG/WebP。现有 fake provider 的该用例返回 PNG，未验证真实 GIF/SVG 字节；原生 Images 结果路径不受同一校验器限制。
- Responses 的独立 svg_usage 尚未套用原生 Images 的 partial/unknown 保护；如果提供者返回该结构，现有图片/宿主计数可能被视为完整证据。此为代码条件推导，不代表真实提供者已返回该结构。
- 两个每连接 WebSocketInbox 复用了共享预算常量，隐式从 48 MiB 增至 64 MiB，超出提案范围；需拆分并保持队列原上限。

该次只读复盘没有修改实现；发现的缺口由下方协议演进实施继续修复。既有通过结果不单独证明修复完成，PR 继续保持草稿。

## 协议演进首轮实施

2026-11-05，macOS arm64、Swift 6.4.2，以下为新实现的本机证据：

- 全量 Swift 485 项通过（Core 7、Runtime 67、EndToEnd 88、Adapters 323）；新增未知事件不绑定/不续期、回传未知计量、旧响应隔离、closed 后 1009 证据存续、多 lane 未明拒绝、图片不使用输入 codec、多图有效小计及有界名称观察。
- `verify_text_contract.py` 全矩阵通过：HTTP 116、websocket 197 次合成执行；未知字段/大整数/null、事件及用量明细保持，既有失败/计数修正、续接、无重放及私密内容不入日志保持。
- `verify_images.py` HTTP/websocket 配置全矩阵通过：真实合成单帧 GIF、SVG/XML 和 opaque future-format 字节经 Responses JSON/SSE/原生 WS 原值交付；原生未知格式 stream/Accept 与 edits 受测；空/坏/混合输出、非 JSON/错误媒体类型不返回 generation 成功；宿主坏计数、多图部分计数、root/item svg_usage 保留下界与 unknown。重启复用同一组合成 Key 后，持续未知原生图片 SSE 事件不能延长 1 秒首响应期限，504、单派发且 unknown。
- `verify_upstream_ws_body_limit.py` 新矩阵验证未知应用事件后 1009 不回退，以及同连接两个已派发 named lane 的 1009 分别保持 unknown；原有单 turn 明确拒绝、元数据例外、413、容量回收继续回归。responses 与 codex-subscription 两种契约全矩阵均通过。
- Swift 严格格式、文档链接/任务框架、Core/Runtime/Adapter 依赖检查通过。两名 subagent 只读复盘发现的 close/归属与部分计量细节已修正；实际套接字回归不能由 helper 测试替代。

本轮未新增 Core 状态或持久 schema，不重算历史。已知工具阶段事件的重复进展语义仍沿旧行为，未声称全面去重；未知事件则不推进期限。作者 Token/价格的结构化持久与查询表达、混合大输入/大输出/慢消费者的 Linux RSS/FD/task/队列/租约回落，以及真实提供者/客户端兼容仍未完成。GIF fixture 只证明字节交付，不证明动画或 Desktop 显示。

### 首次 Linux 演进验收的修正

`0954a5d` 的 [Linux Verify 42025684434](https://github.com/ximatai/codexone/actions/runs/42025684434) 构建及 484 项 Swift 测试通过，协议分片发现三处验收问题：两个旧夹具仍要求删除未知 usage 明细；图片完整度断言同时暴露费用校验的跨平台问题。费用比较现显式使用 NSDecimalNumber.zero，保证十进制操作数同类型，不依赖 corelibs 的 NSNumber 跨类型比较路径；新增完整图片计数/费用/完整度直接回归。夹具改为保留扩展，并反向验证 metadata ID 不授予私有对象读取权限。图片账本等待还增加 outcome 条件与诊断，避免把未结束记录当最终快照；该等待改进不替代费用修复。

可参考 [Swift corelibs 的 NSDecimalNumber 实现](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/NSDecimalNumber.swift) 理解类型比较分支；实际目标平台结果仍以新 CI 为准。本机全量 485 项、第三分片 11 个脚本、Codex shapes HTTP/WS 及图片矩阵均通过。第一分片补跑发现 JSON 顺序夹具仍删除未知 usage 明细，现改为完整对象保序断言；该用例及其后 JSON、参数、诊断、上下文与压缩回归通过。生产服务没有变更。

## Linux 与发布门禁

代码与测试脚本提交 `d6229aa` 的 Linux amd64、Swift 6.4.1 [Verify 42003725482（第 2 次）](https://github.com/ximatai/codexone/actions/runs/42003725482/attempts/2) 全部成功：构建、全量 471 项 Swift 测试、4 个分片共 44 个协议脚本及文档门禁。首次遇到既有 LAN 回滚测试的临时端口占用，失败任务复跑后通过；未修改生产期限或启动行为。

两路最大正文持有时，/proc 的进程 RSS 高水位为 responses 398944 KiB（约 389.59 MiB）、codex-subscription 405464 KiB（约 395.96 MiB）。只统计网关进程，不包括 fake provider/Python 客户端；这是该合成场景的峰值，不代表所有负载或进程 RSS 硬上限。夹具在建立 WS 连接前准备大正文，逐连接发送并确认派发，保留 10 秒首 create 期限。

该 Linux 结果属于协议演进实施前的基线，不能覆盖本轮新代码；新的自动复跑结果以 [PR #98 检查](https://github.com/ximatai/codexone/pull/98/checks)为准。

没有执行真实付费图片探测或修改线上配置；合成 GIF/SVG 只证明传输、封套、授权及结算，不证明实际格式/账号可用。UI 行为未变。

## 相关文档

[提案](proposal.md) · [任务](tasks.md) · [验证约定](../../development/verification.md)

## 作者计量与多 lane 收尾补验

作者输入/输出独立于宿主和渲染计数，纳入每日上限；推理不重复累计。计数与价格覆盖独立，未知费率不阻止计数结算。macOS Swift 6.4.2 顺序 492 项测试通过，含 schema v12 显式迁移、旧证据缺失保留、日汇总和 Key 重启上限；前端 lint/format/typecheck、215 项单元测试、64 项既有 Chrome 用例及 2 项新增 SVG 大/窄屏合成用例通过。新增用例实际滚动抽屉检查作者字段并检查无横向溢出，截图仅合成数据。

完整接口脚本发现既有多 lane 收尾竞态：只使用两个 1 KiB create 的独立复核中，24 次有 7 次在第二个错误交付前关闭。连接 owner 修复后独立复核 24/24 错误齐全，另 8/8 排队补测只派发原两条，账本保留 unknown；不是放宽脚本断言。原 413/取消/断连及 Codex 形状接口回归通过。修复后的最终 Swift/全接口及原生 Linux 检查仍按提交检查结果验收。

Release 安装演练新增实际 v0.26.9 生成 v11 库、候选显式迁移及备份、旧程序拒绝 v12 的门禁；尚待 CI 镜像演练，不能据本机合成测试宣称通过。完整混合资源门禁与实际订阅 GIF/SVG 仍待验收，未合并、部署或发布。

## 混合容量候选门禁

新增 `verify_mixed_capacity.py`：同一网关三轮，双 32 MiB 输入/9 MiB 等待/接近 8 MiB 小正文、32 MiB 输入与约 46 MiB 原生多项结果、generation 慢读完整 SHA-256 核对、edits 部分读取取消、已派发大正文断连、再次取得 32 MiB 容量及管理查询存活。取消 edits 使用独立合成主体；30 次派发按主体核对，成功项必须完整结算，另 3 条断连 unknown 保留责任。

Release capacity suite 使用同一 CI 候选镜像、原生 Linux amd64，刺激 512 MiB 与网关 768 MiB 独立容器/cgroup，均禁 swap、只读、无外网。每轮恢复采样 60 秒；FD 回落、绝对 RSS 包络与相对首轮暖机恢复尾段中位数的 32 MiB 增量门禁并行校验，记录双方退出/OOM 状态，失败也保存白名单证据。它不是 Swift Task/队列/lease 直接归零证明；后者仅有容量再次可取的行为证据。多 lane 和 zstd 仍由独立接口矩阵验收，不冒充同进程组合覆盖。

4 项边界/责任测试及 macOS 三轮功能 smoke 通过；macOS smoke 只等待 1 秒，不声称 Linux 内存验收。原生优化镜像资源门禁尚待最终 Release dry-run。实际 Codex CLI 0.165.0 的三种传输、目录发现、文本/工具/压缩 18 个合成场景全部通过：58 次上游派发均结算，含 22 次 lite 请求；没有真实账号调用。

补充实际默认配置对齐：生产支持的图片并发为 2，混合脚本也使用并发 2。以两个约 46 MiB 输出各已发送首 chunk 的有界 barrier 确认重叠，在同一 32 MiB 输入持有期间检查管理 GET 和另一 Key 小请求，再核对完整 generation 哈希与 edits 取消。假上游共享不可变 fixture，避免刺激自身重复构建多份大 JSON；本机完整三轮通过，原生 Linux 最终门禁仍待执行。

补验普通正文的合计容量：17 项 Swift 定向测试覆盖两池、大小到达顺序、空等待及原子转池。真实 HTTP/原生 WS 套接字在预留充满时均明确 503、无派发，关闭未完成正文后普通请求与 32 MiB 请求可再次派发；两种上游契约通过。旧实现同一小正文断言返回 200，证明用例可区分旧行为；没有进行内存耗尽实测。新合计预留上限不等于物理 RSS，最终原生 Linux 镜像仍须完成混合验收。
