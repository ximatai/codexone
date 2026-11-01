# 账号授权失败原因

设备码批准后及回调兑换失败目前统一为 authorization_failed，无法区分提供者拒绝、兑换、验证与身份冲突。本变更按任务 brief 推进，不访问真实订阅或部署。

## 契约与范围

遵循[身份规范 I15/I16](../../reference/specs/identity.md)和[控制面 A12](../../reference/specs/control-plane.md)：适配器/用例用类型化错误携带封闭失败类别，Core 不依赖传输框架。新增 provider_rejected（设备请求非等待、非成功 HTTP 状态）、exchange_failed（兑换网络、超时、格式错误）、verification_failed（PKCE、nonce、JWT 声明）、identity_mismatch（重新授权 namespace 不同或已绑定账号）。保留 revision_conflict、device_code_unavailable 和未知错误回退 authorization_failed。

Runtime 每次进入 failed 仅写一条 warning，字段仅 method、failure_code 和可选数字 provider_status；不记录错误原文、响应体、凭证或提供者身份。过期、取消及停止沿用原寿命与收敛责任，不增加重试。前端对设备码和回调显示中文原因，未知代码使用通用提示。

## 验收与兼容

合成 socket 覆盖轮询 400/429/500、兑换拒绝/超时/畸形、PKCE/nonce/JWT、重新授权身份冲突、重复绑定、CAS 与存储失败；断言单条安全日志、无秘密和无重放。前端单测覆盖所有文案及未知代码，浏览器检查大屏和窄屏失败对话框。执行 brief 指定的文档、前端和最终一次后端全量验证。

API failureCode 增加枚举值，UI 和 API 客户端必须接受新值并为未知代码回退；回调 POST 沿用安全错误格式，兑换失败统一为 503/account_unavailable（过去可识别的 invalid_grant 曾返回 409/authorization_required）；详细分类从同 owner 的流程状态读取。无 schema/持久格式变更，旧代码保留通用回退，二进制回退无需迁移；流程仍只在内存，重启后重新发起。

## 相关文档

[任务](tasks.md) · [变更约定](../README.md)
