# Rust 账号与 Key 治理

管理适配器覆盖 Key 列表、选项、发放、轮换、策略、停用、归档、命名和到期设置，以及账号列表、命名、模式、强制停止、刷新和授权。Key 变更与审计同事务提交。账号凭证使用 storage 的 v19 schema 和信封格式，以账号 ID、namespace 和凭证代数绑定。账号授权流程支持设备码与回调，以共享管理认证确定 owner。

## 产品入口组装

- 实现 `Writer`，把命令交给执行层已有的有界 SQLite writer。提供同一 `Database`、事务时钟、可选工作许可。按 `Work` 执行现有读取、可选写入、撤销、刷新准入和关键写入的存储门禁。有压状态下，`Restrict` 命令在事务内确认操作确实收紧权限。治理库在 writer 内开启事务，调用方无需预先开启事务。接纳后的命令不随 HTTP 请求取消而中断。
- 在开放准入前，在启动恢复事务内调用 `recover_refreshes`。它把未完成刷新改为 `auth_uncertain`，保留原意图及凭据信封并写入审计。关闭时先停止管理接纳，等待授权和刷新停止，再关闭 writer。
- 从启动配置交付凭证加密器；纯 Key 实例使用 `GovernanceApi::keys_only`。账号实例向 `Authorizations` 和可选的 `RefreshService` 提供受信上游。由上游适配器固定 OAuth 端点、验证 TLS 和身份、核对回调 nonce 与设备码 PKCE，并分类无响应和 provider 拒绝。由管理入口提供 `AccountRuntime`，接入账号运行态、现有执行取消登记和刷新服务。
- 和基础管理路由共用同一 `AdminRouter`。基础路由未匹配时调用 `GovernanceApi::route`，沿用管理监听器限制。Key 选项可从 `KeyOptions::configured` 构造，启用模型目录时提供当前目录投影。HTTP 会话认证、Cookie 续期和 CSRF 继续由 admin crate 管理。
- 授权流程由 `GovernanceApi::shutdown` 等待收敛。已提交 writer 的凭证操作会完成，轮询和兑换在停止时取消。使用刷新服务时，另调用 `RefreshService::shutdown`，等待已记录的刷新意图收尾。

## 验证

```sh
cargo test --locked --manifest-path rust/governance/Cargo.toml
cargo clippy --locked --manifest-path rust/governance/Cargo.toml --all-targets -- -D warnings
```

合成对照覆盖旧 Key 元数据、有效与失效 CAS、审计失败回滚、撤销容量、浏览器会话与回调消费、设备轮询与取消、凭证代数与刷新恢复。对照依据为 Swift `KeyGovernanceTests`、`AccountGovernanceTests`、`AccountAuthorizationTests` 和管理 HTTP 路由。生产 writer 和上游适配器接入、真实提供者、整站 SPA 与平台发布由集成后验证。
