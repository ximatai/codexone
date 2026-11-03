# 上游 WS 正文上限任务

跟踪合成验收与发布前由维护者执行的真实上游验证。

- [x] 发送前一次编码及 16 MiB 判断，安全的一轮 HTTP 回退
- [x] JSON/SSE/native 确定性错误、无未知执行或账号惩罚
- [x] 本地真实 binary 合成边界、续接、拒绝、取消、账本及字节序验证
- [x] 阅读固定 revision 官方客户端源码并记录处理行为
- [x] macOS build、docs、定向验证及完整 backend 一次
- [ ] 发布前维护者真实上游/HTTP 大小验收（本任务不执行）

2026-11-03，macOS arm64 本地合成验证：`swift build -j 12`、`python3 scripts/check_docs.py`、`verify_upstream_ws_body_limit.py`、`verify_json_order.py` 均通过；账号池定向 Swift 测试的成功/413 × 状态头/正文四组通过。真实 binary 矩阵使用单身份本地 fake，账号池使用生产服务与合成账号的进程内端到端测试；不把后者声称为真实 binary 的账号池验收。大图片字段为不经 codec 解码的合成不透明字节，只验证传输，不验证真实图片/模型接受。

官方源码 revision 与 413 上层仍可能重试的限制见[兼容说明](../../reference/compatibility.md#大请求错误的官方客户端源码核查)。`./scripts/verify.sh --backend` 一次完整通过：428 个 Swift 测试、38 个后端脚本（含新增矩阵），格式/文档/架构检查通过。无 Linux 构建、真实账号/提供者请求或部署验收。

规范及回退影响见 [proposal](proposal.md)。

## 本次补全

- [x] 早期真实 1009：独立 HTTP 单轮同账号回退；原生/续接 413、完整零用量；其他关闭与生命周期后 1009 不变
- [x] reader 在入队前建立生命周期屏障；metadata 不提交后再回退；原生拒绝后同客户端 socket 后续小 turn 可用
- [x] 保持 32/48 MiB 限制；四档大小桶及 ingress/budget 拒绝诊断
- [ ] 真实 binary 合成失败矩阵、RSS 测量与最终一次 backend verify（执行后记录）

## 相关文档

[协议规范](../../reference/specs/protocol.md) · [贡献指南](../../../CONTRIBUTING.md)
