# 模型目录透传验证

日期：2026-10-30。平台：macOS / Darwin arm64。

范围：受信离线快照 upstream 读取与完整性校验、未知嵌套成员保留、slug/priority/视觉/原生 WS 覆盖、内联 catalog 整体覆盖及旧合成路径、缺 profile 的 503、策略/计价版本隔离、离线导入工具，以及既有后端回归。只使用合成数据与本机合成上游；没有真实账号调用、部署、推送或 PR。

| 命令 | 退出码 | 结果 |
|---|---|---|
| `swift build` | 0 | `Build complete!`；既有 SQLiteKeyMaintenance 解码属性警告不影响构建 |
| `swift test 2>&1 \| tail -20` | 0 | 203 项通过（35 + 36 + 3 + 129），含新增 3 项 upstream/profile 测试；使用 pipefail 核实 Swift 退出码 |
| `./scripts/verify.sh --backend` | 0 | 文档、依赖边界、严格 Swift 格式、构建、203 项测试及所有后端脚本通过 |

新增测试证据：

- Swift：原始未知嵌套成员与视觉/WS 开关组合；配置 slug/priority；内联 catalog 覆盖后沿用 unified_exec 合成路径；slug 不符、缺失/空/非字符串指导、单条超256 KiB、catalog/upstream 共存、快照超4 MiB拒绝；超过旧1 MiB上限与超过旧32 KiB指导上限的合法 upstream 导入成功。
- 策略：单身份与账号池中，快照来源哈希或 upstream 内容变化改变策略版本，计价版本不变。
- socket：`verify_protocol.py` 的 upstream 私有快照在 `/v1`、`/backend-api/codex` 返回预期完整条目；未知成员保留、视觉与 WS 收敛、来源信息正确；既有 catalog 与缺 profile 的 503 场景保持通过。
- 导入：`verify_model_profiles_import.py` 已接入 backend；正常转换、缺模型/重复选择/重复源 slug、已有输出/链接拒绝与精确0600权限通过。

主 Agent 复核：同日在普通 macOS 环境（依赖经按 `Package.resolved` revision 预取的本地镜像解析，锁文件不变）重跑 `./scripts/verify.sh --backend`，退出码 0，Swift 203 项及全部后端脚本通过。

未验证：Linux verification；部署后真实 Desktop 采用目录。二者保持未完成，后者仍需单独授权。
