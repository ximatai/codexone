# Key 归档与模型范围验证

日期：2026-11-01。平台：macOS arm64。只使用合成数据、独立临时状态及 loopback 上游。未运行 Linux/Docker、真实订阅、OpenAI 调用、服务器或部署验证；未 push/开 PR。STATUS.md 未修改。

## 覆盖与证据

- 归档：启用中拒绝、重复归档、恢复未归档、revision 冲突；归档后启用/策略/轮换/显示名/到期修改全部拒绝，认证与持久准入拒绝。恢复仍停用，随后可单独启用。SQLite 实际审计含 archive/unarchive，审计写失败回滚。默认与 archived=true 在过滤后限页，130 个交错条目分成两组各 64+1 页；管理 API 同样覆盖参数校验与游标。keyOptions 保留名称并含 archived，历史用量与已准入结算保留，attention 无归档 Key 提醒。
- 模型：null 显式编码与元数据往返，缺 models 拒绝，[] 仍为无对话授权的仅图片 Key。单身份/账号池当前配置目录与有效策略一致；替换配置后新增立即可用、移除立即失效，显式旧清单不会扩大。策略版本区分 null 与显式清单。HTTP/WS 合成端点覆盖 Responses 图片工具和 Images，未配置模型不派发，关闭图片生成后拒绝图片工具。
- 导入/导出：离线清单的 models/imageModels null 经导入、读取与重启保留，仍默认停用。source 模式的源 SQL NULL 输出 null；非 null 源清单取已配置交集，无交集隔离；所选条目隔离则整次拒绝。覆盖 CLI 缺配置清单拒绝、实际输出 null、旧显式模式与源 schema 校验。
- 前端：组件覆盖归档确认、默认隐藏、回收站读取与恢复、恢复仍停用、启用中禁用入口提示、两类模型范围独立切换、null payload、指定清单切换往返保留、归档 Key 用量限额读取、跨页 archived 参数。现有 409 刷新核对与未知结果锁沿用共享 owner。Chrome 新增用例在 1600×1000 完成归档/恢复和模型编辑，并在 390×844 检查无横向溢出；已人工检查编辑抽屉、归档大屏和窄屏截图。
- 独立 subagent 前端只读复核无 P0/P1；两项 P2（范围切换丢失未保存清单、空回收站文案）已修复并纳入组件/浏览器验证。

## 出口结果

完整入口各执行一次；失败后仅补验失败入口和此前未执行的后续步骤，不重复已通过检查。完整后端首次唯一失败是既有十万条用量查询预算测试，在 Chrome/前端验证并行运行时返回 capacity；浏览器结束后原测试定向通过，未改实现、预算或测试。完整前端首次在新增测试的类型检查处失败（Testing Library 不支持 exact 选项）；改为精确正则后类型检查通过，随后执行全部组件测试、构建和 Chrome。后续脚本还发现 verify_admin.py 的 keyOptions 严格等值断言未包含新增 archived 字段，补上 archived=false 后该脚本及未执行的最后四项通过。未更改其余实现或放宽校验。所有标准入口的组成检查均已通过：Swift 304 项（303 项在全量运行通过、1 项定向补验）、Vitest 143 项、Chrome 36 项及全部 33 个后端合成脚本。


| 命令 | 退出码 | 耗时 | 关键结果 |
| --- | --- | --- | --- |
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 1 | 63.03s | 文档、架构、Swift 格式、构建通过；Swift 303/304，唯一失败为既有用量查询预算测试 |
| `swift test --disable-sandbox --no-parallel -j 12 --filter round2UsageQueriesStayBoundedAtOneHundredThousandAttempts` | 0 | 11.94s | 原预算测试通过，测试本身 1.397s；未修改代码/预算 |
| `bash .tmp/backend-remaining.sh` | 1 | 459.99s | 按 verify.sh 原顺序执行其 Swift 测试后的命令；前28项通过，第29项 verify_admin.py 在旧 DTO 断言处失败 |
| `bash .tmp/backend-tail.sh` | 0 | 15.25s | 修正断言后从 verify_admin.py 续跑，最后5项全部通过；累计33个标准后端脚本均通过 |
| `./scripts/verify.sh --web --chrome` | 1 | 2.83s | lint、format 通过；新增组件测试使用了不支持的 exact 类型选项 |
| `npm --prefix web run typecheck` | 0 | 0.37s | 改用精确正则，类型检查通过 |
| `npm --prefix web test` | 0 | 7.88s | 29文件、143项通过 |
| `npm --prefix web run build` | 0 | 1.99s | 类型与生产构建通过 |
| `npm --prefix web run test:e2e:chrome` | 0 | 51.46s | 36项通过，含新增归档/模型范围及大屏/窄屏操作 |
| `python3 scripts/verify_key_export.py` | 0 | 0.14s | source SQL NULL、源清单顺序/去重交集、无交集隔离、CLI缺输入拒绝、旧模式通过 |
| `python3 scripts/check_docs.py` | 0 | <0.1s | 227份文档与本地链接/变更产物通过 |

`.tmp` 下两份临时 shell 仅提取标准入口中尚未执行的原命令，使用相同构建产物和原顺序，没有跳过脚本或改变参数；不作为新的仓库验证入口。迭代还执行了新增 Swift 定向测试（4项通过）、Key组件定向测试及新增 Chrome 用例。临时日志已脱敏，不进入提交。

## 契约校准与边界

- 原导出 approval 只有 models/limits/selectedName，无法在 models="source" 时取得当前配置。新增显式 --configured-models-file（有界、普通 JSON 数组文件）供非 null 源清单求交；缺失拒绝，旧显式模型数组行为不变。提案与摘要导入规范已同步。
- “配置变化即时生效”沿用既有配置加载/重启入口，指配置生效后 null Key 自动跟随，无需再更新 Key；没有新增热重载或运行时配置通道。
- 旧二进制不能解码 null 模型范围；回退前须将全部模型 Key（含归档条目）改为显式清单，并满足不限限额与 schema 的既有回退前提。归档继续占 Key/普通审计容量，不提供硬删除。
