# 管理接口参考

为同源管理面板和本机自动化提供认证后的管理操作索引。

## 认证

浏览器使用 `/api/session` 的内存会话、Secure/HttpOnly/SameSite=Strict Cookie；写入要求精确可信 Origin 和 `X-CodexOne-CSRF`。非浏览器本机客户端可使用独立管理员 Bearer，不携带 Cookie、Origin 或 Sec-Fetch-Site。两种认证不可混用，数据 Key 不授予管理权限。

## 接口索引

| 路径 | 用途与详细契约 |
|---|---|
| `POST/GET/DELETE /api/session` | 登录、读取会话和退出；空闲 24 小时、最长 7 天 |
| `/api/keys`、`/api/keys/options` | [创建、分页、revision 更新、轮换、归档/恢复](../guide/key-governance.md) |
| `/api/accounts`、账号 authorization/refresh | [账号元数据、模式与一次性授权](account-credentials.md) |
| `/api/usage`、`/api/usage/keys`、`/api/usage/daily`、`/api/usage/in-flight` | [查询、按 Key 统计、日趋势与进行中](specs/usage.md) |
| `/api/usage/headroom`、`/api/runtime/storage` | [治理余量与存储水位](../operations/storage-pressure.md) |
| `/api/attention` | [待处理提醒](specs/control-plane.md) |
| `/api/system` | 系统就绪检查 |

## 失败与敏感字段

更新使用 revision CAS，409 后先读取最新元数据。网络错误后的写入结果可能未知，不自动重放。secret 仅在创建/轮换时一次性返回；账号 token、密文信封和 Key 摘要不由读取接口返回。请求/响应与分页硬限制见控制面规范，不应将这里的索引理解成宽松校验规则。

## 相关文档

[控制面规范](specs/control-plane.md) · [管理面板](../guide/admin.md)
