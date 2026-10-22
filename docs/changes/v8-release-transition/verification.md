# v8 候选与切换验证 · 2026-10-22

主 Agent 亲自实现与执行，仅本机合成资料；没有真实账号调用/额度、旧服务修改、推送、发布或服务器部署。

## 产物与实际检查

- 当前候选精确源码 `890bf2c9c54f8615c6541a129cabece8c6745610`；镜像 `sha256:0f7e975e11580a8d7466f977d32956534d0e32efd3b99908de49321180bd002b`，优化运行程序 SHA-256 `3f04ccf776657b247009e678213d28ca179ed0d95ee8ea9f1d97b3df94504ac8`，与 verification 中逐字节相同。schema v8、Swift 6.4.1 / Node 22.23.0 固定基底；仅 Adapters release 关闭 WMO，仍保留 `-O`。当前程序构建 359.40 秒。
- 真实兼容 peer 的产品源码为 `06058077d2cfa988f094ff50265202cd0721f919`，只对其构建 manifest 加入相同 Adapters 分文件 release 设置（不是改旧产品行为）。镜像 `sha256:483f1b4d21694278d1b1c6333e631cb116fde83ec8d8559e41ba7a707a9f36ba`，程序 SHA-256 `507f8c2dfc2e537390f164ad2d4917966b10d1d97b3df94504ac8`，构建 641.02 秒；实际构建源码/补丁另归档，未用同程序换 tag 冒充回退。
- `python3 scripts/verify_installation.py --image codexone:v8-candidate --previous-image codexone:v8-rollback-baseline --incompatible-image codexone:m6-candidate --browser --browser-output artifacts/v8-installation-ui` 通过：实际交付 Compose/受控入口、非 root/只读/权限/卷归属拒绝、768 MiB/128 PID、live/ready、SPA/session/CSRF/Key；v8 存储观测和真实物理储备、离线 key-status/bundle/verify；同卷换旧 v8 再升级、同 keyring ID、Key/未知哨兵保留。v5 语义夹具普通启动拒绝、私有一致性备份/显式幂等迁移到 v8、旧权限保守解释、重启均通过。结构性未知哨兵不冒充真实协议执行。
- Chrome 1440 宽实际操作镜像 SPA：登录、Secure/HttpOnly/Strict session、发 Key/清除秘密/刷新保留、登出通过；`artifacts/v8-installation-ui/desktop.png` 已查看，未覆盖旧阶段截图。curl relay 不证明 TLS；真实 TLS 另见下。
- 合成迁移脚本在 macOS arm64 / Swift 6.4 debug 与 Linux amd64 优化程序均通过：在途阻止切换/暂停拒绝、独立一致性旧备份、原公开 Host/两个前缀、换发 Key、剩余配额实际耗尽且不调用上游，产生真实 settled/unknown、停新进程、唯一切回审计/重复回滚、保留新账与旧备份、旧侧继续按新责任拒绝且无重放。legacy 是独立 SQLite/HTTP fixture，不是 CodexLB 实现或真实导入器；只有一个主体，不能推导通用跨主体基线迁移。
- Linux 在无外部网络、非 root/只读、768 MiB/128 PID、512 MiB 私有 tmpfs 下另执行 `verify_migration_cutback.py --binary /output/codexone --previous-binary /peer/codexone`：同一真实执行库换旧 v8 再升级，attempts 全列、evidence 全行、全部绑定不变；settled 确有持久证据，旧 Key 仍认证，耗尽配额仍拒绝且无新上游调用。
- 优化程序完整 15 个后端脚本集合通过：Docker verification 的协议/WS/Images、主密钥、快照、存储与迁移，加独立相同约束容器的 process/Key/admin/pool-config/context/compaction/execution/accounts。后者使用仅验证层拥有的优化 ExecutionProbe；运行镜像不包含测试 probe/SDK/Python/源码。Swift 业务 Sources、Tests、web 产品源码相对前阶段没有变化，保留已通过的 175 项 Swift 和前端全集证据，不重复。
- 真实新 binary + 打包 SPA 的 TLS/Nginx 在与修正后 CI 相同的 non-root/read-only/network-none、768 MiB/128 PID、noexec 512 MiB tmpfs 下通过：CA/主机名正反、HTTPS session/CSRF/Origin/Host、前缀/JSON/SSE/WSS、取消/超时/unknown/无重放和 Nginx/文件失败清理。macOS 本机初始化/二进制配置定向检查、最终迁移脚本回归，文档/架构/Package 格式/YAML/差异及新增文件隐私检查通过。

## 失败、集中 review 与归档

首轮旧 release 构建遇 Docker 后端 EOF，未产出可验收结果，原因未定，不称为 OOM 或通过；全依赖分文件尝试主动中止后，收窄至仅 Adapters 设置并完成真实优化构建。首轮优化维护检查遗漏测试专用 ExecutionProbe，补建到 verification 层后通过，未加入运行镜像。

两位 subagent 集中只读 review，主 Agent 修复并复审关闭三项 P2：TLS CI 原 64 MiB 卷不足以补足储备，增至 512 MiB 后真实 TLS 全过；真实回退快照改为完整执行/证据/绑定并验证非空证据；旧 v6 通用错误不能证明 schema 拒绝，补同产物/配置/UID/卷/密钥在独立 v6 子目录成功 live、文件权限/归属一致的正向对照，停止对照后才验证主 v8 拒绝和真相不变。PASS 文案按实际启用参数区分。相关安装和真实执行回归通过；未重复未改变的 Chrome/协议全集。

本机忽略目录 `artifacts/linux-candidate-v8/` 保留新/旧两个镜像、精确当前源码与旧实际构建源码归档、镜像/程序/产品 revision、限定验证元数据和 SHA256SUMS。校验全部通过，实际 `docker load` 同时重载两个镜像成功；旧 `artifacts/linux-candidate/` v6 保留。一次本机校验工具使用了 Python 3.9 不提供的 file_digest，改用流式 SHA-256 后完成；未把未生成校验账的中间包当成完成。

这不是远端 CI、目标弱宿主容量、掉电、真实账号/旧服务切换、Desktop 或 M5 验收。兼容 peer 只在上述配置/schema/证据组合上通过，不保证任意同 schema 二进制；旧快照恢复仍须维护态与缺失区间核对。下一闭环是容量演练，含恢复缓存的完整 O14 出口仍有 M5 前提。
