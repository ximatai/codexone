# 验证与复盘

## 2026-10-22 · 加密与持久屏障切片

主 Agent 亲自实现与自我复盘。macOS arm64 / Swift 6.4，只有合成材料，不读取个人授权文件、不调用提供者或真实账号。

`./scripts/verify.sh --backend` 通过：边界、严格格式、构建、60 个 Swift 测试及全部真实进程/协议/Key/session 脚本。新增 8 个测试覆盖 AEAD 随机 nonce、篡改/错误密钥/身份/namespace/version、非法/超量信封、主密钥文件权限/符号链接、刷新 CAS 与并发禁用、密文先改但审计失败时事务回滚、旧 intent 重启变 uncertain、可信身份变化拒绝及重新授权、v2 显式迁移保留 Key。v1 的快照/失败回滚回归继续保留，普通启动不静默升级。

`verify_accounts.py` 纳入统一验证，真实独立进程分别在刷新 intent 前、intent 后和提交后 SIGKILL：重启得到 ready v1、auth_uncertain v1、ready v2；中断刷新不能再开始/迟到完成旧刷新，DB/WAL 不含 token 或主密钥。测试经 Core 用例和实际 Crypto/SQLite，不拿内存 helper 冒充持久屏障；不代表掉电或上游刷新协议。

审计容量自我复盘：仅固定上限会使已开始刷新没有结束位置，或挤占全部账号的禁用。现实现按事件数 + 未完成刷新数计算剩余空间，开始同时预留两条，另有 64 条真实禁用空间。真实库测试将普通边界填满，64 个活动刷新期间全部禁用，重启仍能为全部写入 uncertain；不删除历史或把旧 token 自动 ready。完成刷新保留期间最新模式，不因回调重新启用账号。

尚未接入 Runtime 单飞、提供者身份验证/授权、账号管理界面或账号池数据面，也没有生产主密钥配置入口；这些任务继续保持未完成，不声称完整 M3 验收。该切片 review 与 Linux 结果见下节。

## 2026-10-22 · 独立 review 与修复

bace11b 的 reviewer 实证 P2：域允许合计 32 KiB 的合法 token，其中 `/` 会被默认 JSON 编码为 `\/`，导致超过明文 33000 字节检查，合法刷新结果被不必要地拒绝。主 Agent 仅为凭证 payload 设置 withoutEscapingSlashes，保持 AAD 的既有编码不变；原有信封仍可正常解码。补最大 access/refresh 各 16 KiB 的 slash 密码学往返，以及真实 SQLite/Core 刷新完成后仍 ready、新版本可解密的回归。

修复后 4 个凭证/应用定向测试通过，扩展的真实 SQLite 用例再次单独通过。reviewer 独立完成原提交的 8 个相关 Swift 测试与三个 SIGKILL 场景，未发现其他阻塞问题。98f9746 复审关闭 P2，无新增阻塞；reviewer 独立运行三项定向测试通过，包括最大 slash 与真实 SQLite 刷新。

bace11b 精确快照在 Linux amd64 / Swift 6.4 本地容器完整后端验证通过：60 个 Swift 测试和全部脚本（含三组账号 SIGKILL），exit 0。98f9746 修复快照另在同平台重建后通过 4 个凭证/用例测试及三组真实 SIGKILL，exit 0。均单并发、2 CPU/2500 MiB，本地模拟而非弱服务器/远程 CI；容器正常退出并已回收。修复快照没有重复整个后端，完整结果仅对应原提交，边界回归单独验证。
