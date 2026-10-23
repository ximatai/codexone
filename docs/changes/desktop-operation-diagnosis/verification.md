# Desktop具体拒绝诊断 · 2026-10-23

实际用户截图确认ChatGPT Desktop 26.1016.62342（2026-10-22发布），运行于另一设备。界面重连5/5并显示Gateway request failed；不能将本机CLI 0.163.0-alpha.11.1通过推断该版本已通过。本次电脑操作工具明确禁止控制本机Desktop，未用其他UI接口规避，另一设备亦无已确认的操作通道。

## 历史证据边界

主Agent只读复核已有测试服务的固定错误码/服务端UUID及所选启用Key的账本枚举：工具拒绝记录仍为unsupported_tools/400；原warmup/generation各1、settled/succeeded只能证明该Key有成功执行，不能与截图失败操作唯一对应。原日志没有具体工具分类，未读取消息正文、工具schema、凭证或个人登录，也不通过猜测恢复其内容。具体根因仍待新增诊断下的受控真实操作关联。

本机可选配置的脱敏检查不是另一设备配置，不用于归因。官方配置说明核对来源为[Advanced Configuration](https://developers.openai.com/codex/config-advanced/)，其说明本地CODEX_HOME与自定义provider配置作用域；实际版本行为仍以实验及用户设备为准。

合成辅助对照：固定本机CLI在不显式关闭web_search时，默认内置目录仍成功；显式目录路径返回unsupported_tools。两次使用同一loopback实际fixture和固定合成文本，默认一条上游、显式目录拒绝前未新增调用。它只证明不同目录/工具组合仍可能产生差异，不证明另一设备失败就是内置搜索，更不是Desktop验收。

## 本地诊断实现与定向验证

新增16项固定工具reason，保留原允许集合、数量/大小及公开错误code/字段结构；已知搜索/发现/MCP类型只分类，仍拒绝。无新增正文日志、原始类型名/工具名/字段值日志，也无主体/Key或客户端可控关联标签。

- swift build -j 4：exit0。
- Swift定向ProtocolFailureDiagnosticsTests/Lite声明、容量及WS继承共10项通过。
- verify_tool_diagnostics.py：16种原因交替覆盖HTTP/WS，错误UUID与日志逐一对应；公开错误只有原4字段，20次拒绝最多16日志，无任意私有工具字段/描述/正文/Key/路径，无上游连接/attempt/绑定。
- verify_protocol_rejections.py和verify_lite.py通过，旧reasoning/首WS错误/容量/归属拒绝及成功续接保持。

实现提交d83e30c后，按用户最新要求停止刚发起的subagent复核，后续由主Agent自审，不将中止复核记录为review通过。macOS完整verify.sh --backend exit0，198项Swift测试（35+35+3+125）及全部后端脚本通过，新增16类原因/关联/隐私检查在组合入口内实际执行；136份文档及差异/隐私检查通过。Linux和测试服务更新在完成后补记。没有具体Desktop操作/分类证据前，不标根因已查清或Desktop通过。

为真实界面能关联拒绝编号，后续仅在unsupported_tools的message附加已经存在的有效服务端UUID；内部reason仍不公开，不接收客户端任意标签，其他错误文案保持。4项Swift诊断单测及16类真实socket检查覆盖提示编号与日志/响应字段一致，任意非UUID不会进入提示。首个d83e30c诊断构建的Linux verification已通过；加入界面编号后的最终Linux检查另记，不能混作同一受测产物。

使用新增分类补采集同一合成目录对照，明确该辅助场景的拒绝为tools_builtin_search；默认目录仍成功。此记录只定位本机合成对照的内置搜索分支，另一设备Desktop失败原因仍不可据此认定。

最终候选源码bec950f（含工具拒绝提示UUID），Linux amd64 verification target exit0；真实剥离程序通过16类HTTP/WS reason/Reference关联与隐私无派发、协议/WS/Lite/fixture/图片及维护/恢复/存储/切回定向检查。运行镜像标准安装验证exit0，实际程序与该verification产物SHA一致；未用初版d83e30c的无Reference产物代替。更新测试服务及真实Desktop结果在完成后补记。

## 实际Desktop关联结果

含Reference的bec950f诊断候选已完成受控备份/校验并升级独立合成测试服务，运行程序SHA256为72a1fefc4fbc33fa1385388a4ab22b60c87cd745870520afb443b694e9d2e1b5，与已验Linux产物一致。原配置/数据/属主、fixture及provider进程、反代及旧服务不变；仅原测试Key启用，账号0、unresolved0。公网双前缀HTTPS JSON/SSE及WSS成功对照通过，五个合成拒绝的Reference与预期reason精确匹配；诊断Key已撤销。

用户保持原配置，在另一设备实际Desktop新会话发送约定合成探针，界面报带Reference的网关错误。服务端精确UUID匹配到2026-10-23 10:41:19 UTC的unsupported_tools/tools_description；该请求在工具声明校验阶段拒绝，不能将其他成功执行归于此请求。该旧分类同时代表null、其他非字符串或说明超过32 KiB，尚不能确定其一，也不能推断存在搜索/数量问题。下一步仅拆分该诊断并作最小对照，不据猜测放宽行为。

说明分类细分保持拒绝行为不变：null单列、其他非字符串仍tools_description、超32 KiB单列。macOS build、4项诊断单测、18类HTTP/WS关联/无派发/隐私（说明三分支均覆HTTP及WS）、Lite双前缀成功与拒绝回归、格式/文档/差异检查通过；未采集原说明或其他请求值。Linux与再次运行更新仍在进行，不记为已完成。

细分候选源码2e02014的Linux amd64 verification全部通过，包含实际剥离程序18类诊断关联（说明三分支均HTTP/WS）、协议/WS/Lite/fixture/图片及维护/恢复/存储/切回；runtime安装验证通过。运行镜像sha256:615b8e8e2603fa9f67a2f0d5d13d7ee7d49134d3aad9b1478a2beda3a1c1605e，程序SHA256 d6a215e1e529112a8df129ea1acaffef9a7390182a532c84cdaf9766f2143df6，与verification程序一致。独立合成测试服务已备份/校验后更新，首轮成功，未重启provider；原配置/数据/属主、fixture、反代及旧服务不变，账号0、unresolved0、仅原Key启用。

更新后公网双前缀HTTPS JSON/SSE、WSS预热/续接成功；null/超长/其他非字符串五个合成错误的界面Reference均匹配具体服务端分类，临时Key已撤销。仅为诊断及合成对照通过，不能证明原Desktop问题已经修复。诊断就绪后请求用户保持同一实际客户端配置再做一次受控合成操作；等待该Reference以确定具体子分类，未采集请求正文或工具原值。没有推送、发布、真实订阅调用或旧服务变更。

## 长说明拒绝确认与修复 · 2026-10-23

用户下一次同配置实际Desktop操作的界面Reference，精确对应2026-10-23 11:04:46 UTC的tools_description_size/unsupported_tools。确认至少一条说明超过32 KiB，未记录说明、精确长度或其他字段值；不能归因为null、类型错误或上游失败。此前32 KiB是CLI样本推定，未覆盖实际Desktop组合，属于网关兼容及容量基线缺口。

修复将单条32 KiB改为跨全部顶层/Lite包/namespace的512 KiB UTF-8说明共享预算；保留纯文本总请求512 KiB、图片外层8 MiB及所有类型/数量/深度/身份限制，不删减或截断声明。官方[Function calling](https://developers.openai.com/api/docs/guides/function-calling)区分function/custom/namespace说明及工具上下文成本；本项目预算为自身资源策略，不将其说成官方协议上限。

macOS定向6项Swift测试通过：长说明两入口接受、精确预算/UTF-8及跨来源/namespace不能重置。实际HTTP JSON/SSE、桥接/原生WS、Lite/compact双前缀验证长function/custom/namespace说明完整转发；预算超限、总文本超限、类型/重复等拒绝不派发、不建attempt/绑定，18类原因/Reference与隐私回归通过。首轮新大帧负向被测试发送helper的旧512 KiB断言挡住，扩展其显式测试上限参数（默认不变）后重跑通过；不将该测试夹具失败写成产品通过。完整后端、Linux及部署在完成后补记，真实Desktop保持未通过。

主Agent自审后，macOS完整verify.sh --backend exit0，199项Swift测试（35+35+3+126）及全部后端脚本通过，136份Markdown/架构/格式检查通过。未改变前端，不重复前端全集；未以CLI替代Desktop操作。Linux出口及修复服务更新仍待完成。

修复候选56600c0的Linux amd64 verification与runtime安装验证均exit0；实际剥离程序通过HTTP/WS/Lite/fixture/图片/维护/恢复/存储/切回及18类诊断检查。镜像sha256:d6044bdcafc55df6f26352576c1f3eda4d6d6d312a2dadfe3a7009fcc79ff823，程序SHA256 3c1ca4962474e60336dec8d312ae72caa8c169f6ea50dd814cb61bdd5b6f897b，与已验程序相同；精确源码/校验和候选保存在忽略的artifacts/tool-budget/。

独立合成测试服务备份及备份校验后升级成功，运行SHA匹配；原Key/数据/配置/属主、fixture及provider启动时间、反代和旧服务不变，账号0、unresolved0。公网两个前缀HTTPS JSON/SSE和WSS预热/续接均带131073字节合成说明通过（旧阈值会拒绝）；五个说明错误的Reference与日志逐一匹配。临时诊断Key已撤销，仅原Key启用。没有真实订阅调用、Git推送或发布。诊断与修复验证就绪后，请求用户在同一实际Desktop保持配置进行一次受控操作，等待界面结果；该结果到达前仍不标真实Desktop通过。

## 真实Desktop文本操作验收结果

更新修复后，用户在同一另一设备ChatGPT Desktop 26.1016.62342保持原配置，新建会话发送约定合成探针，明确反馈界面显示完整预期固定测试回复（说明未调用真实模型或订阅）。这是用户实际Desktop操作与可见结果，不是CLI、渲染页面或本机配置推断。

随后只读核对运行源码仍为56600c0；本次窗口所选原Key新增2026-10-23 11:20:03—04 UTC的warmup/generation各2条，全部settled/succeeded，unresolved0、真实账号0、仅原Key启用。当前容器除五个已精确识别的合成负向探针外无工具拒绝，healthy、无OOM或重启。账本条数不等同用户点击次数，也不据此声称无内部辅助调用或逐条与界面请求ID匹配；验收依据包含用户已确认的真实界面成功，未只凭同Key或相近时间认定。

本次版本/设备/配置下的新会话文本发送与合成回复展示通过，说明旧单条32 KiB拒绝已在实际操作中消除。没有真实订阅/额度调用或读取请求正文、工具说明、凭证。该单次文本场景不证明所有Desktop工具/图片/连续主动编辑、真实订阅或M5恢复、完整容量验收，不将完整M2/M4/M5/M6及整体首版标完成。
