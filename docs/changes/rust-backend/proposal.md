# Rust 后端

定义第二套后端的兼容与运行边界。

Swift 兼容基线为 3c82d71f47b1c14a05a1e450fcd29b3061755aec。以 [能力规范](../../reference/specs/README.md) 和该提交的公开行为为验收基线。Rust 独立构建，保留管理前端、配置、公开协议、SQLite schema、凭证和备份格式。同一数据目录同一时间只有一个后端。切回同基线 Swift 前正常停机，使用独立副本验证双向读写及故障恢复。

领域层决定准入、归属和结算；传输层拥有连接和有界缓冲；专用写连接执行原子业务命令；运行时监督收尾与关闭。先分别交付可独立测试的 wire、存储兼容和跨实现验证模块，再集成执行与管理链路。共享 Cargo workspace 和发行入口由集成方维护。差异以合成输入记录，涉及外部行为的变更单独提案。

Rust 镜像通过显式构建参数选择 Linux amd64 候选，使用相同的 SPA、Ubuntu glibc 运行根、CA、维护工具、权限、健康探针和容器资源约定。构建输出必须携带源码版本和 schema 版本。[运维规范](../../reference/specs/operations.md) O06、O08 和 O14 适用。构建入口本身不迁移数据。发布前需在原生 Linux 上用独立合成状态验收混合容量与同 schema 双向切换。

## 相关文档

[交付与验收](tasks.md)

## 默认安装与发行切换

Linux amd64 源码构建省略 `CODEXONE_BACKEND` 时生成 Rust。常规 Release 的版本 tag 与手动 dry-run 走同一个 Rust 构建和验收路径。按照 [O06/O11](../../reference/specs/operations.md#o11发行与容量验收细则)，测试分片、实际 Compose 安装、Nginx TLS 与混合容量检查必须验证同次构建产物。发布仍以经验证的镜像归档为唯一输入。

Compose 安装继续接收经核验的不可变镜像引用。切换不新增安装参数或 schema 版本；当前 v19 库沿用同一配置、密钥和卷。过渡期间可显式以 `CODEXONE_BACKEND=swift` 构建同源码镜像，停服并核对兼容性及备份后再按镜像回退流程切换。发布门禁要区分候选 Rust 进程的证据与 Swift 专用探针的证据。
