# 技术选择的验证依据

- [明确版本客户端续接与恢复契约](client-recovery.md)：正常续接、EOF 重连和输出读取的证据边界。
- [CodexLB接入行为对照](codexlb-compatibility.md)：明确源码版本的恢复、认证额度、图片、目录与期限差异，不代替线上或客户端验收。
- [CodexLB讨论依据](codexlb-discussions.md)：Issue/PR动机、维护者取舍与合并边界，对应后续兼容设计方向。
- [网关活跃度与关键故障对照](gateway-reliability.md)：CLIProxyAPI/LiteLLM 的目录、多轮、授权、终态与用量证据及本项目适用边界。
- [真实链路后的协议对齐复盘](protocol-alignment-review.md)：协议基线、同源夹具、校验职责和真实验收顺序的方法教训。
- [文本协议对照矩阵](text-protocol-matrix.md)：固定官方/成熟项目来源、本地校验职责、接受与拒绝范围、剩余真实验证缺口。
- [文本协议验证摘要](text-protocol-validation.md)：最终受测产物、覆盖、重要失败结论和证据边界。
- [普通输出与请求参数验证](ordinary-output-parameters.md)：多视图语义关联、可信后端契约、首轮准入与独立socket/账本证据。
- [真实订阅验证与责任账](real-subscription-validation.md)：八次受控生成、历史未知/失败、账本摘要和清理核对。

原型来源：[ximatai/codexone](https://github.com/ximatai/codexone)，参考提交 `3af8a52fe131b81cbe1a5ca043eaf14e7cbe9bb5`。依据限于该原型及对应测试环境，不能推导正式项目已实现或通过。

- macOS 与 Linux amd64 合成传输/协议验证支持 Swift/NIO 数据面方向；Vapor 高层 HTTP 的静默断连对照存在缺口，因此应掌握 channel 生命周期。
- macOS Codex CLI 0.163.0 的文本、工具、续接、压缩及原生出图验证，为目标兼容路径提供依据。它不等于 Linux live、所有客户端或生产账号池验收。
- CLI 原生出图涉及独立 Images generation，不能只实现 Responses 图片工具；客户端能力声明不等于网关授权。

不据此宣称 OAuth/刷新、多账号隔离、财务幂等、持久恢复、缓存安全、长期容量或 ARM/systemd 已被证明。原始报告及迁入过程在来源仓库和本项目 Git 历史中追溯，不在正式文档复制实验整包。
