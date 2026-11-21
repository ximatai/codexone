# CodexOne Rust 管理 HTTP 路由

管理路由库提供健康检查、只读系统摘要、现有 SPA 静态资源和内存浏览器会话。兼容约束见[管理规范](../../docs/reference/specs/control-plane.md)和 [Rust 后端提案](../../docs/changes/rust-backend/proposal.md)。

## 产品入口组装

1. 以 `codexone_config::Configuration` 加载启动配置。绑定管理 loopback 监听后，用实际非零端口、`runtime.listen_address`、`admin_digest`、`admin_origin.as_deref()` 和 `web_bundle.take()` 构造一份 `AdminRouter`。同一管理服务的监听器共享该实例。只将该路由接到管理监听器。
2. 入口按监听配置检查连接来源，限制 32 个管理连接，并在接受连接后 10 秒内收齐不超过 8 KiB 的请求。保留 HeaderMap 中的重复请求头，以便路由拒绝歧义。正文过大可使用 `request_too_large()` 返回 413。
3. 将收到的 `http::Request<Bytes>` 与实时 readiness 回调传给 `AdminRouter::route`。返回 `None` 时由产品入口继续匹配业务路由或使用 `not_found()`。输出最多 1 MiB，5 秒内写完并关闭连接。为普通响应补全 Content-Length，保留路由为 HEAD 返回的原正文长度。
4. 受保护的业务路由可先调用 `AdminRouter::authorize`，将返回的 `AdminAuthorization` 应用于对应响应。浏览器写操作校验 Origin 和 CSRF，独立 Bearer 拒绝浏览器凭证头。应用用例、管理并发门禁和 WebSocket 生命周期由产品入口接入。`revoke_sessions()` 会清空当前实例的浏览器会话，替换实例会重置会话存储。

静态资源使用配置层验证并加载的启动快照。会话凭证由系统随机源生成，只在内存索引保留 token 摘要和 CSRF 证明。重新登录时，旧 Cookie 仅用于定位要替换的会话。缺失、过期或无法解析的 Cookie 不影响正确凭证重新认证。登录 JSON 沿用 Swift 对同名键读取首值的行为。

## 验证

```sh
cargo test --locked --manifest-path rust/admin/Cargo.toml
cargo clippy --locked --manifest-path rust/admin/Cargo.toml --all-targets -- -D warnings
```

契约测试直接调用 HTTP 路由，使用合成凭证和资源，并复用 Swift 与前端的系统状态 fixture。监听限额、慢连接、真实浏览器与业务管理验收在产品入口接入后完成。
