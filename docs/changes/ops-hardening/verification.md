# 试运行加固验证

日期：2026-10-31。平台：macOS arm64。本 worktree，全部合成数据；未访问部署实例、真实订阅或 OpenAI，未运行 Docker/Linux，未 push/PR。

## 行为与评审

- 全局/身份准入默认容量 1024，单独注入测试小值；主体限额仍为原持久值，Key 策略与静态单身份 Key 的限额不变。账号池候选筛选与最终准入使用同一身份容量，提醒同源；不改写限额元数据、不新增 schema。
- 人工释放 CAS、严格截止、保留 intent/settled/outcome/failure；治理审计与状态在同一事务，审计失败回滚。缺失用量不补零，已有可信部分证据保留且查询显示 unavailable/数值下界；迟到部分证据不重占容量，完整证据可修订统计。
- 提醒按总未结（含恢复缺失暴露）50%/80% 分级；可释放 count 与总占用 unresolvedCount 分开，limit 同源。
- 账号到期元数据只从应用层提取；失败为 null。15 分钟临期不冒充已观察到的刷新失败，沿用现有授权/额度失败提醒。
- 独立 subagent 评审后修复部分证据展示、恢复暴露统计与容量范围隔离问题；前端零条释放禁用，未知结果可刷新核对后解锁。
- Chrome 1440×900 合成流程覆盖确认/取消、409 刷新、成功释放、账号名回退及凭证到期。确认框截图已人工检查，内容与按钮完整、无横向溢出；截图为忽略的本地构建产物。

## 验证结果

| 命令 | 退出码 | 耗时 | 结果 |
|---|---:|---:|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 500.46 秒 | 构建、格式/架构、Swift 266 项及全部后端标准脚本通过 |
| `./scripts/verify.sh --web --chrome` | 0 | 22.94 秒 | lint、格式、类型、Vitest 109 项、生产构建、Chrome 13 项通过 |
| `python3 scripts/check_docs.py` | 0 | 0.04 秒 | 203 份 Markdown、本地链接、变更记录完整性通过 |
| `swift test --disable-sandbox --no-parallel -j 12 --skip-update` | 0 | 39.86 秒 | 最终容量隔离实现的全部 Swift 266 项通过 |

先前标准脚本与重编译重叠时出现候选进程启动失败；受影响脚本定向重跑通过（12.72 秒），最终固定候选串行完整验证通过。初次鉴权测试遗漏可信 Origin 时被既有来源保护拒绝；修正测试后真实 HTTP 鉴权/CSRF/字段校验/CAS/繁忙/no-store 全部通过。

范围限制：未执行 Linux/Docker、真实凭证刷新或部署验收。下一步由主 Agent 按既有授权进行 Linux verification 和部署评估；若产品需要独立的临期提醒，应另定义真实刷新状态来源与展示规则，不能将临近到期当成失败。
