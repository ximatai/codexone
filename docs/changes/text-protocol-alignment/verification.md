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
