# 验证记录

2026-10-23，用户实际请求的临时入口脱敏元数据为多次WS 101后短时关闭及HTTP回退400；所选Key无attempt/持久拒绝。证据支持握手认证通过与首条消息建执行前拒绝，不等于已确定具体字段。

主Agent实现首条WS解析失败的标准错误帧（不反射未经验证的lane），沿用关闭、无上游/无intent语义；HTTP/WS错误响应处记录固定码白名单与服务端UUID，未知值归other，单调窗口16/60s溢出丢弃。

macOS arm64定向2项单测、实际进程拒绝/无上游连接/无attempt或binding/16条上限/正文Key路径不入日志通过；原HTTP/WS全场景定向回归通过。测试初版Swift Testing宏不接受mutating表达式，改为先求值再断言，产品逻辑不变。随后macOS完整后端182项Swift与全部后端脚本通过。Linux amd64同一优化候选在无外网、只读、非root、512MiB/2CPU/pids128、1GiB临时盘的隔离容器中，protocol_rejections/protocol/websocket/trial_provider全部通过；没有重跑无新增改动的前端全集。提交16082eb后集中review无新增P1/P2。

候选 `codexone:rejection-diagnostic-candidate`，源码 `16082eb9c84b2e2bccb7ee3daf918a92cdfd7964`，镜像ID `sha256:fb2c26d82de20d325c1643488e84a26c101e65b2ccd25fbe0e19cbfa2eb45ea0`，Linux程序SHA256 `e413efd62e3c2058d27edb8aa320342126de95e5b9e072421a6cd824f800d7eb`；源码归档/镜像与校验账留在忽略产物目录。旧候选保留。

管理SSH曾在认证前关闭，未传输/更新；按用户建议经既有Clash代理恢复受控管理连接，未改全局模式或新增客户端转发端口。临时入口元数据诊断已由owner恢复关闭；新侧已更新，同一镜像/程序SHA复核通过，公网两前缀JSON/SSE/WSS及401/404/撤销Key/308通过；诊断Key全部撤销，仅所选源Key启用、unknown=0，旧服务容器/镜像未变且healthy。身份/管理员配置未变，新侧Compose仅增加local容器日志2MiB×2轮转并实际inspect验证。

受限代理上传发生中断，未提前加载不完整镜像；仅对本次自有文件分段/压缩续传，先核对已有前缀再补尾段，最后完整归档SHA和运行二进制SHA都验证一致。临时管理连接无客户端转发端口、带owner与结束期限；不修改Clash全局模式或TUN设置。

用户不改配置再次操作后，进程脱敏日志明确出现 `unsupported_reasoning` / 400，unknown=0；客户端反馈未特殊配置reasoning选项。新建诊断Key的合成公网对照：summary=null或effort=null均同码400，明确effort=medium、summary=auto为200；诊断Key随即撤销。这证实可选null的兼容缺口，与实际错误一致，但尚无真实请求字段值证据，不能断言只剩此问题。后续修复仅known reasoning成员的null语义，不放宽未知字段或错误类型。Desktop、真实订阅和M5仍未通过。
