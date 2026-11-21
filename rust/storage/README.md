# CodexOne Rust storage

独立 Cargo crate，面向兼容基线 Swift 后端的 SQLite v19 数据库。支持打开现有数据库，校验版本、有序列名和 SQLite `quick_check`。与 Swift 共用实例锁，检查未完成的恢复和凭证重加密标记。打开后启用 WAL、`synchronous=FULL` 和外键约束，沿用 250 ms 写连接忙等期限。

凭证兼容 v1 AES-256-GCM 信封、单主密钥文件和 format 1 keyring。旧密钥可解密，封装使用 active key。Key 模块提供托管 Key 的 Bearer 校验和 SHA-256 十六进制摘要。

## 事务边界

`Database` 持有单一写连接及实例锁，提供 `BEGIN IMMEDIATE` 事务供持久化适配器使用。后续仍需实现这些应用语义：

- 启动时恢复执行 intent、unknown exposure 和刷新 intent，核验凭证与配置，决定何时开放准入。
- 准入、账号与 Key 策略复核、额度保留、绑定及证据结算，连同取消、重试、用量汇总和待核对释放。
- 账号与 Key 的创建、策略调整、撤销和轮换，包含 CAS、刷新结束及审计。
- 有界写入队列、容量门禁、读取连接管理、迁移、新库初始化、备份、恢复及凭证重加密命令。

## 验证

```sh
cargo test --locked --manifest-path rust/storage/Cargo.toml
rust/storage/tests/verify-swift.sh
```

第二条需要仓库规定的 Swift 工具链、Python 3 和本地 Swift 兼容基线提交。脚本在临时位置构建基线 Swift 包。Swift 创建隔离的合成账本、账号和托管 Key，持锁时 Rust 拒绝打开。Swift 正常关闭后，Rust 读取并解密旧信封，以 active key 重新封装，并写回信封和新 Key 摘要。Swift 随后打开同一数据库，解密新信封并按新摘要认证。测试中的直接 SQL 更新只用于验证持久格式。
