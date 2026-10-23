# Desktop具体拒绝诊断 · 2026-10-23

实际用户截图确认ChatGPT Desktop 26.1016.62342（2026-10-22发布），运行于另一设备。界面重连5/5并显示Gateway request failed；不能将本机CLI 0.163.0-alpha.11.1通过推断该版本已通过。本次电脑操作工具明确禁止控制本机Desktop，未用其他UI接口规避，另一设备亦无已确认的操作通道。

## 历史证据边界

主Agent只读复核已有测试服务的固定错误码/服务端UUID及所选启用Key的账本枚举：工具拒绝记录仍为unsupported_tools/400；原warmup/generation各1、settled/succeeded只能证明该Key有成功执行，不能与截图失败操作唯一对应。原日志没有具体工具分类，未读取消息正文、工具schema、凭证或个人登录，也不通过猜测恢复其内容。具体根因仍待新增诊断下的受控真实操作关联。

本机可选配置的脱敏检查不是另一设备配置，不用于归因。官方配置说明核对来源为[Advanced Configuration](https://developers.openai.com/codex/config-advanced/)，其说明本地CODEX_HOME与自定义provider配置作用域；实际版本行为仍以实验及用户设备为准。

合成辅助对照：固定本机CLI在不显式关闭web_search时，默认内置目录仍成功；显式目录路径返回unsupported_tools。两次使用同一loopback实际fixture和固定合成文本，默认一条上游、显式目录拒绝前未新增调用。它只证明不同目录/工具组合仍可能产生差异，不证明另一设备失败就是内置搜索，更不是Desktop验收。

## 本地诊断实现与定向验证

新增16项固定工具reason，保留原允许集合、数量/大小及公开错误；已知搜索/发现/MCP类型只分类，仍拒绝。无新增正文日志、原始类型名/工具名/字段值日志，也无主体/Key或客户端可控关联标签。

- swift build -j 4：exit0。
- Swift定向ProtocolFailureDiagnosticsTests/Lite声明、容量及WS继承共10项通过。
- verify_tool_diagnostics.py：16种原因交替覆盖HTTP/WS，错误UUID与日志逐一对应；公开错误只有原4字段，20次拒绝最多16日志，无任意私有工具字段/描述/正文/Key/路径，无上游连接/attempt/绑定。
- verify_protocol_rejections.py和verify_lite.py通过，旧reasoning/首WS错误/容量/归属拒绝及成功续接保持。

提交后review、受影响全集、Linux和测试服务更新在完成后补记。没有具体Desktop操作/分类证据前，不标根因已查清或Desktop通过。
