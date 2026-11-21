# CodexOne Rust storage

独立 Cargo crate，面向兼容基线 Swift 后端的 SQLite v19 数据库。与 Swift 共用实例锁，校验 schema 版本、有序列名和 SQLite `quick_check`，检查未完成的恢复标记。写连接启用 WAL、`synchronous=FULL` 和外键约束，忙等期限为 250 ms。

凭证兼容 v1 AES-256-GCM 信封、单主密钥文件和 format 1 keyring。旧密钥可解密，封装使用 active key。Key 模块提供托管 Key 的 Bearer 校验和 SHA-256 十六进制摘要。

## 事务边界

`Database::open_existing` 只接受现有 v19 库。`Database::open_or_create` 可以初始化空库，自动迁移已启用增量回收的 v13–v18。两个入口都会拒绝未完成的凭证重加密。

`Database::migrate` 持锁离线迁移现有 v1–v18 库，按需启用增量回收。v19 无需迁移。升级先检查可用空间，再使用 SQLite Backup API 生成同目录的私有单文件备份 `<数据库名>.pre-v<来源版本+1，最小13>-<ID>.sqlite`，同步文件及父目录后才执行 schema 迁移。迁移事务内校验新 schema 和完整性，失败保留源 schema 和已完成的备份。离线迁移保留凭证重加密检查点及待恢复的执行记录。

`Database` 持有单一写连接及实例锁，提供 `BEGIN IMMEDIATE` 事务供持久化适配器使用。后续仍需实现这些应用语义：

- 启动时恢复执行 intent、unknown exposure 和刷新 intent，核验凭证与配置，决定何时开放准入。
- 准入、账号与 Key 策略复核、额度保留、绑定及证据结算，连同取消、重试、用量汇总和待核对释放。
- 账号与 Key 的创建、策略调整、撤销和轮换，包含 CAS、刷新结束及审计。
- 有界写入队列、运行期容量门禁、读取连接管理、管理 CLI、完整快照备份与恢复及凭证重加密。

## 验证

```sh
cargo test --locked --manifest-path rust/storage/Cargo.toml
rust/storage/tests/verify-swift.sh
```

第二条需要仓库规定的 Swift 工具链、Python 3 和本地 Swift 兼容基线提交。脚本在临时位置构建基线 Swift 包。Swift 打开并写入 Rust 创建的 v19 库，并以 v9 离线迁移和 v18 启动迁移对照 schema、已迁移记录和迁移前备份。双向测试还验证实例锁、旧信封解密、以 active key 重新封装以及更换托管 Key 摘要后的 Swift 认证。
