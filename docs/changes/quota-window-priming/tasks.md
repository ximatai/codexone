# 空闲窗口预热任务

跟踪空闲配额窗口预热的实现与合成验证。

- [x] 阅读已有 reset-credits 提案/任务/提交、观察/执行路径及能力规范，记录维护者决定。
- [x] Core 检测/设置/屏障与内部执行端口，扩展 v11 状态/审计/恢复。
- [x] 正常执行通路、固定账号、最小参数、账本与失败/取消测试。
- [x] Runtime 有界 owner、观察提示、退避/停止与 attention。
- [x] 管理 CAS/配置验证与账号设置表单、单元和桌面/窄屏验收。
- [x] 更新 identity/usage/control-plane、维护说明、STATUS/CHANGELOG。
- [ ] 文档与前端检查，最后一次 backend 验证，公开差异审查与聚焦提交。

验证记录：仅合成数据；12 项定向后端测试（含 HTTP/WS 参数化场景）、197 项前端单元测试、46 项 Chrome 场景通过；1440/390px 表单截图已检查。文档、架构、Swift 格式、前端 lint/format/build 通过。最后一次完整 backend wrapper 正在执行，完成后将过程归纳到规范。

## 相关文档

[变更约定](../README.md) · [身份规范](../../reference/specs/identity.md)
