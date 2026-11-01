# 设备码账号授权

拟把设备码登录作为添加和重新授权订阅账号的默认方式，保留回调粘贴作为备用。

## 问题

现有流程要求管理员在浏览器登录后，从打不开的 `localhost:1455` 页面复制回调地址贴回管理台，再单独启用账号。远程部署时这一步最难理解，也最容易出错。

上传本机 `auth.json` 不作为替代：refresh token 每次刷新都会轮换，网关与本机 Codex 共用会互相顶掉登录，严重时可能整组失效；上传的 JWT 也不能作为身份来源（[I15](../../reference/specs/identity.md)）。

## 提供者协议

以官方 Codex 客户端的设备码登录为依据（`codex-rs/login/src/device_code_auth.rs`，核对于 2026-11-01）：

1. `POST <issuer>/api/accounts/deviceauth/usercode`，JSON `{client_id}`，返回 `device_auth_id`、`user_code` 与字符串形式的 `interval`。404 表示该服务端未开启设备码登录。
2. 用户在 `<issuer>/codex/device` 登录并输入 `user_code`，有效期 15 分钟。
3. 轮询 `POST <issuer>/api/accounts/deviceauth/token`，JSON `{device_auth_id, user_code}`。403/404 表示尚未完成；成功返回 `authorization_code`、`code_challenge` 与 `code_verifier`。
4. 在固定 token endpoint 以 `redirect_uri=<issuer>/deviceauth/callback` 和返回的 verifier 兑换授权码。

## 范围

### 后端

1. **流程**：管理授权用例新增设备码流程种类。创建时请求 user code，返回 `userCode`、`verificationURL`、期限与轮询建议；`device_auth_id` 只驻留内存，不进入 DTO、日志或持久存储。
2. **轮询所有权**：轮询由 Runtime 监督的服务拥有，不依赖前端保持连接。间隔取提供者建议并夹在 [3, 30] 秒，单次调用沿用 I15 的总期限与响应上限；403/404 视为等待，其余状态、畸形响应或网络不明结束流程，不自动重试兑换。
3. **兑换与身份**：轮询成功后由同一 owner 一次性消费，经 I15 固定 token endpoint 兑换。设备码流程没有本地 nonce，ID token 不做 nonce 比对，其余 issuer/audience/有效期/subject/account 校验不变；信任来源仍是可信直接传输，不放宽到任意上传的 JWT。
4. **容量与期限**：与回调流程共享每 owner 与全局容量（最多 8 个流程、4 个并行完成）；设备码流程期限取提供者有效期与 15 分钟中的较小值。停止服务时取消并等待全部轮询和兑换。
5. **API**：`POST /api/accounts/authorization` 增加 `method: "device" | "callback"`，默认为 `device`；新增 `GET /api/accounts/authorization/:flowID` 返回 `pending | completed | failed | expired` 和完成后的账号 ID；`DELETE` 取消流程并停止轮询。user code 仅在创建响应与本 owner 的状态读取中返回。
6. **结果**：新账号仍以禁用保存，重新授权仍绑定 id/revision 并保持命名空间（I16 不变）。提供者返回 404 时结果为 `device_code_unavailable`，供前端引导改用回调方式。

### 前端

1. “添加账号”和“重新授权”默认显示 user code、可复制的验证链接与倒计时，后台轮询状态；完成后在同一弹窗显示结果。
2. 新账号完成后提供“启用”按钮，仍是独立的明确操作。
3. 底部提供“改用浏览器回调方式”；收到 `device_code_unavailable` 时自动提示切换，并说明可能需要在 ChatGPT 安全设置中开启设备码授权。
4. user code 只在页面内存，离开或关闭即取消流程。

## 不做

- 上传或导入 `auth.json`、读取本机 Codex 缓存。
- 移除回调粘贴方式；是否移除待设备码长期稳定后再评估。
- 自动启用新账号，或在失败后自动重新发起流程。

## 规范影响

- [身份](../../reference/specs/identity.md) I15：允许设备码兑换不做 nonce 比对，并说明其信任依据。
- I16：增加设备码流程种类、轮询所有权、期限与取消语义。
- [控制面](../../reference/specs/control-plane.md)：授权 API 的 `method` 字段与状态读取。
- [管理指南](../../guide/admin.md) 与 [账号凭证](../../reference/account-credentials.md)：新的默认流程与备用方式。

## 验收

- **合成提供者：** 用真实 socket 覆盖以下情况，并确认网络与存储都收敛：
  - 等待、成功与 404 未开启；
  - 轮询期间 403/404、其他错误状态与畸形响应；
  - 期限到期、管理员取消、服务停止、兑换失败与身份冲突。
- **安全：** user code 和 `device_auth_id` 不进入日志或持久存储；不同 owner 不能读取或取消彼此的流程；兑换只发生一次。
- **前端：** 浏览器中操作完整流程，含成功、不可用后切换回调、取消与倒计时到期，检查 1440×900 与窄屏。
- **真实账号：** 经维护者明确同意，用自己的账号完成一次设备码授权，只登录、不消耗额度，记录日期与结果。
- **数据：** 不改变 schema；回退到旧版本不受影响（流程只在内存）。

## 相关文档

[任务](tasks.md) · [变更约定](../README.md)
