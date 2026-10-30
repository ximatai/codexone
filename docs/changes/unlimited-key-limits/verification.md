# Key 无限额验证

日期：2026-10-30。平台：macOS 27.2 arm64，Apple Swift 6.4，Node 22.22.0 / npm 10.9.4。仅使用合成数据与 loopback 上游；未调用真实账号、未部署、未暂存或提交文件；STATUS、deploy、Package.swift、Package.resolved 和前端锁文件均未修改。

## 命令与结果

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `swift build --disable-sandbox` | 0 | `Build complete!` |
| `swift test --disable-sandbox` | 0 | 四个测试 target：35 + 36 + 3 + 132 = 206 项通过 |
| `swift test 2>&1 \| tail -20`（临时 SwiftPM 包装器） | 0 | 最终重测通过；使用 pipefail 保留真实测试退出码 |
| `./scripts/verify.sh --backend`（临时 SwiftPM 包装器） | 0 | 文档/架构/Swift 格式、构建、206 项 Swift 测试与全部后端脚本通过；最后输出合成迁移切回 PASS |
| `python3 scripts/verify_key_export.py` | 0 | 只读固定 schema、source 推导、隔离与所选 Key 整次拒绝 |
| `python3 scripts/verify_key_import.py --binary .build/debug/codexone` | 0 | 私有原子导入、null 元数据往返及重启保留，HTTP/WS 激活和失败路径 |
| `python3 scripts/verify_keys.py --binary .build/debug/codexone` | 0 | HTTP/WS 两组通过；null 创建/更新/读取、非法字段拒绝及合成执行 |
| web：`npm ci --ignore-scripts --no-audit --no-fund --registry=https://registry.npmmirror.com --cache <temporary-cache>` | 0 | 完整性校验保留；未修改 lockfile 或 npm 配置 |
| web：`npm run lint && npm run typecheck && npm test` | 0 | 13 个测试文件、47 项通过 |
| `./scripts/verify.sh --web --chrome` | 1 | lint、format、typecheck、47 项组件测试、生产构建通过；四项浏览器测试均在启动 Chrome 时失败，未执行页面操作 |
| `git diff --check` | 0 | 无空白差异错误 |

默认 `swift build` 首次在 manifest sandbox 初始化时退出 1（`sandbox_apply: Operation not permitted`）。本环境按 brief 使用 `--disable-sandbox`；完整后端脚本通过仓库外临时 PATH 包装器，仅向 SwiftPM build/test/package 子命令添加该参数，仓库脚本和包清单均未改动。npm 默认缓存不可写，改用仓库外临时缓存后安装成功；安装还提示部分依赖建议 Node ≥22.22.2，但上述前端检查实际通过。

Chrome 子进程在启动时 SIGABRT，清理进程提示 EPERM；独立浏览器工具也返回 `The browser access host is unavailable`。没有生成有效页面截图，不将浏览器操作或视觉检查标为通过。新增 1600×1000 桌面端到端用例已进入检查入口，须由具备浏览器运行能力的环境复验。

## 验收覆盖

- SQLite 实际准入逐个切换五个字段为 null：原数值阈值拒绝，改 null 后准入；每个其他维度仍可独立拒绝。全 null Key 完成 105 次执行（超过既有合成 Key 的 100 次阈值），第 106 次仍被全局限制拒绝；账本与重启元数据保留。
- 每个限额的缺字段、0、负数、超 10¹²、非数字字符串拒绝；Core 另拒绝布尔值。显式 null 编解码保留五项；null/数值切换改变策略版本，提供者 scope 和价格保持。
- 管理 API 创建、更新、列表和导入/重启往返保留 null。全局限制仍要求显式数值；没有 schema 变更。
- source 导出无记录时五项 null，有任何记录时隔离，所选 Key 隔离则整次拒绝；缺表、缺列、新增列均拒绝。固定列集合只读，同一事务快照；显式数值策略行为保留。
- 前端组件覆盖五项“不限”选择/取消、恢复数值、互斥禁用、null payload、列表和用量展示。同一 Key 重查用量也重读当前限额。
- 前端独立 subagent review 无 P0/P1，发现“重查用量但限额陈旧”P2 后已修复并补测试。浏览器与 Linux 出口仍未验收；Linux/部署不在本 brief 范围。

## 主 Agent 复核

同日在普通 macOS 环境复跑：`./scripts/verify.sh --backend` 退出码 0（206 项 Swift 测试、全部后端脚本）；`./scripts/verify.sh --web --chrome` 退出码 0（47 项组件测试、生产构建及包括新增“不限”用例在内的 4 项 Chrome 浏览器测试）。上文执行环境中的 Chrome 启动失败以此复验为准。
