# 验证记录

## 2026-10-24 · 主Agent本机阶段

固定官方SDK/Codex及CLIProxyAPI源码已只读核对；矩阵逐项列出请求、代理、响应元数据、事件、关联、上下文和用量的依据/接受范围/未验证项。SDK新增合法形态仅作为独立缺口证据，尚未宣称为第五笔实际拒绝的唯一原因；不计外部项目测试通过。

新增独立字面量JSON事件及socket提供者，不调用trial_provider.response_events构造响应。macOS arm64初步HTTP与websocket两组通过：JSON/SSE/桥接/native、完整输出窗口两轮、float时间/指令对象列表/可空原因、超过旧256 KiB回显、错误类型/容量/状态/总数/外来response ID、usage与失败独立持久、扩展/metadata ID不授予绑定、无重放及无正文日志。最新HTTP稀疏流/完整大请求回显与全部既有后端回归正在运行，未提前计为完整出口。

开发中的夹具失败不计通过：首次配置文件漏设私有mode，启动即被安全校验拒绝；SSE尚未提交时错误会回JSON，探针已按实际HTTP状态解析；普通JSON没有独立SSE事件名，不能以其status=failed断言为事件名/状态矛盾，改为只在确有事件的路径验证。一次格式命令缺recursive标志立即失败，随后仅格式化改动文件。以上不改产品授权、失败或持久语义。

本阶段尚未新增真实调用、上传或部署；既有5笔真实记录和私有账本保持。Linux、实际候选安装、真实两轮与Desktop不由本机初步结果推导。

macOS arm64 / Swift 6.4完整`./scripts/verify.sh --backend` exit 0：203项Swift、格式/依赖方向/文档及全部后端socket/进程/持久脚本通过。新增独立协议套件HTTP 45次、websocket上游71次，共116次执行，包含JSON/SSE/bridge/native；每组核对准确上游次数、关闭后账本及无重放/正文日志。新增稀疏HTTP流从delta.response_id建立关联且无status仍可完成；WS保持更强created前置。300000字节实际请求指令回显经过三条传输/两轮，超过旧事件上限仍原样保留；超过新1 MiB的扩展事件拒绝且unknown，不授予证据。主Agent完成自查，Linux仍在编译，不计已通过。

Linux首轮verification未通过：独立HTTP成功组一笔响应完整而关闭后outcome为failed，可信usage 5/3仍完整；当时探针只报告kind，没有保存细分failure，不能认定唯一原因。检查发现收尾等待误用不存在的pending，真实在途状态为intent，可能过早SIGTERM；已按intent等待有界收敛，保留严格succeeded/failed及用量断言，增加固定outcome诊断/定向case入口，不改变产品结算或结果语义。相同runtime程序在独立无网络Linux容器重跑116次套件通过，修正等待后再复查10组HTTP成功路径、40次执行通过，未重现；完整Linux出口和最新Mac定向仍在运行，首轮失败不计通过。

核查图片配置和现有实现后，更正P13/P14遗留的连接/传输聚合/WS共享队列数字，未改变任何运行容量；目标弱宿主O14仍保留。此前已构建runtime实际OCI/Compose初始化、非root/只读、SPA/Key持久、锁/迁移/重启检查exit 0；不能据runtime安装通过跳过verification失败。

探针修正后macOS独立套件116次执行再次exit 0；应用程序未改动，未重复已通过的203项Swift/其余后端全集。Linux完整verification正在复跑，不将独立诊断容器通过替代该出口。

完整Linux复跑仍失败，现明确为HTTP/details-empty组第一笔JSON在完整响应后settled/failed、failure=indeterminate，用量5/3完整，其他三笔成功；据此排除“仅探针提前停服”的解释。保持原失败账本断言，按提案补完整JSON批量提交及已提交终态的同步结果观察；不改Core first-observation、计量或未知执行语义，不在写入前记录成功。新程序macOS定向build exit 0，下一步重新执行受影响完整后端/Linux/实际安装与快速关闭负向，尚未恢复真实调用。

新程序macOS完整后端首轮在代理stall错误组即时读账失败：错误JSON批写比finalizer收敛更早可见。改为3秒内严格等待unknown，不删失败断言；该完整命令不计exit 0。203项Swift及此前全部脚本已通过，代理完整套件定向复查exit 0，随后顺序补跑其余全部后端脚本（含独立116次、工具/压缩/图片等）；不为测试等待改产品持久或取消语义。Linux新程序已通过完整协议/代理/独立116次/工具/fixture/Images检查，维护段仍在运行，阶段出口尚待完成。


原文本对齐/收尾修复出口（程序04543be）：macOS首轮203项Swift与前置脚本、修正等待后的完整代理及其余所有后端脚本分别exit 0；不将首轮命令失败写为一次全绿。Linux新程序完整verification exit 0后发现最后一次测试脚本等待修改未进入镜像，随后按最终源码再次完整verification exit 0；SHA核对代理脚本、独立协议脚本和固定JSON夹具与工作树完全相同。独立HTTP45/WS71合计116次、图片/工具/代理及密钥/快照/低盘/迁移通过。实际Linux amd64 OCI/Compose安装exit 0。一次集中只读复核无新增P1/P2，确认批写与成功观察均在校验/绑定/emit后，未改Core首次结果和未知责任。runtime/verification/服务器运行程序SHA一致：`9f05fc6ce0d07b63400550198bdcb3718972a6bdcd97c09eca3b3b2d1ff2cfa0`。

第六笔真实生成：独立loopback实例、旧服务有效access快照、既有Clash、HTTP/SSE、stream=true/store=false，无refresh/工具/图片；第一轮收到文本后error，固定Reference唯一对应`upstream_usage_container`/`unsupported_upstream_object`，首错停止，第二轮未发送。账本settled/failed，完整input51/output11/cached0、unresolved0；可信计数没有因字段消费失败丢失。新库SHA `858076ea24cde8a3be16180e63b5059e9533724293e3e080aea3a20c41b3d60c`，服务器及本机私有副本核对保留；旧四份库及最早仅外部记录分别引用不变，不以成功或新库抵销未知责任。累计6/8次，两轮仍未通过。该次缺媒体类型与扩展隔离各1次；没有记录原始响应，不能断言具体字段/容量，也不将新metadata策略冒称已证实唯一根因。测试容器正常退出并回收，临时凭证清除，旧服务healthy/身份配置未变，原公开合成入口前后ready；无公开切换、推送或发布。

后续用量分责正在实现：已核对官方新增JSON属性兼容约定；已知计量字段继续严格，未知metadata仅有界保留且不产生权限/证据，补固定容量/明细/计数诊断。尚未运行新程序真实调用。


用量分责开发回归保留：仅接受不透明metadata而原样转发的初稿，旧private-usage检查失败，暴露了未知元数据可能含私有标识的边界；未上传或真实运行该稿。已改为普通纯文本路径在校验/绑定后仅向下游投影已支持计量字段，未知附加元数据移除，图片/独立compact沿原契约；补原private-usage成功但无私有标识、独立嵌套伪计量不影响账本/无绑定/无日志检查。旧Linux编译主动取消，改按最终隔离版本重建，取消项不计通过。一次压缩脚本名误写未执行，已用仓库实际verify_compaction_stream入口补跑；不计误写命令通过。当前隔离版回归仍在运行。


集中增量复核发现并修正1项P2：非终态已知input/output/cached值原依赖终态observeUsage，按键投影可误透出错误字符串/对象。现统一验证全部事件的已知计数类型/范围/cached一致性，但非终态不创建用量证据；加入created/in_progress的错误input/output/cached及metadata隔离实际socket验证。旧候选未上传，按最终修正重新构建；阶段出口仍待回归及复核确认。


修正后macOS完整Swift203项、Images与压缩回归exit 0。新增进行中样例曾错误索引output_item.added并导致提供者KeyError，不能把该断连当协议拒绝；已显式插入独立in_progress字面量，并要求负向同时命中invalid_upstream_usage及固定upstream_usage_count，而非仅有error。最终HTTP73次通过，WS及普通协议仍在运行；Linux最终程序编译中，尚未恢复真实调用。


非终态负向首轮WS记录仍有完整终态用量：独立reader先收到后续有效终态，按既有责任语义正确保留，不能要求其丢失。探针改为负向只发送待拒绝的created/in_progress前缀且不发送终态，保持严格unknown/no-usage；具体错误码和固定原因仍必须命中。最终macOS独立HTTP73/WS128共201次、普通协议/WS/Images/压缩及203项Swift全部通过。实际Linux候选安装exit 0，原有失败记录不抹去；最后脚本版本的Linux完整verification仍在运行。只修改探针不改变产品证据/结果语义。


最终Linux首轮：完整普通协议/WS/代理、独立201次、工具/fixture和HTTP Images通过，但WS Images的invalid-usage未保留预期input5，命令失败，不计出口。追溯为新增已知计数校验在allowMetadata=false时仍继续执行，使图片item.added里的负计数比旧imageResult/终态消费更早拒绝，改变独立reader观察时序；不是立即读账等待问题。修正为图片/独立compact原numeric校验后返回，新增规则只作用于已明确授权的普通纯文本路径。未删除或放宽图片可信计数断言，重新构建并回归后才恢复真实调用。
