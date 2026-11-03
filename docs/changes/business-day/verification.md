# 业务日与首页面板验证

本记录仅含合成数据。本机 macOS 27.2 arm64、Apple Swift 6.4.2、Node 26.13.0、Chrome；不代表 Linux、真实订阅或部署验收。

## 业务日

- `swift build -j 12` 成功。首次依赖缓存读取失败，复制本机缓存至当前工作树后构建；未访问其他工作树。
- `swift test -j 12 --filter businessDay`：值类型 floor/溢出、配置错误、−12/+14、当地午夜与 UTC 午夜限额、事务最终窗口、偏移重启、UTC 汇总映射与恢复冻结通过。
- 用量/Token/恢复相关定向回归通过。
- `python3 scripts/verify_business_day.py --binary ... --previous-binary ...`：真实新/旧二进制、独立临时库、fake provider；配置退出78、限额429且不 dispatch、重启重投影、恢复/核对和普通库回退通过。旧二进制由本分支变更前源码在同一工作树内临时构建，完成后源码已还原。
- 旧版能读 business-day-* 历史执行，按 UTC 准入时间计 Token；非 UTC 恢复核对截止早于旧 UTC 最低截止时，旧版拒绝恢复记录，已实测。见[回退指南](../../guide/backup-upgrade.md)。
- web lint、format:check、208 项单元测试通过；Chrome 1440/390px 业务日日期/查询/布局通过，合成截图在忽略的 artifacts/business-day 下并已目视核查。

事务时间修复已采用：store.admit 返回事务最终 admission，coordinator/context 使用返回值；账号池复用同一事务返回值。异常执行也一次取 now。SQL 只有日表达式 helper 持有偏移算术；rollUp、schema、滚动时长与 UTC 小时网格未改。

## 首页面板

- `swift build -j 12` 与 `swift test -j 12 --filter 'homeKey|businessDay|usage|dailyToken'` 通过，覆盖缺失失败/取消用量与精确失败筛选、诊断排除、限额同源 Token 投影。
- `python3 scripts/verify_home_panel.py --binary .build/debug/codexone`：真实二进制与本机 fake provider；成功后发生无用量 503，摘要仍返回已观测 input=5、cached=0；准入前拒绝不进入 outcome=failed，链接区间内明细数与摘要失败数相等。
- `npm --prefix web run lint`、`format:check`、`test` 随 `./scripts/verify.sh --web --chrome` 完整运行通过；使用 Node 26.13.0，214 项单元测试、64 项 Chrome 测试成功。初次完整运行发现旧浏览器断言仍点击已删除的“全部”切换，更新为检查无此控件后全量重跑成功。
- Chrome 1920/390px 检查六列/窄屏卡片、真实 0%、缺失用量提示、20/5/20% 边界、停用/执行中/取消/未明、详情键盘操作、最近活动排序、空态、503 保留快照、暂停刷新与跨日失败链接；单元回归还覆盖刷新中保持详情的 Key 与快照日期；截图已目视核查。文档首页截图同样仅含合成数据。

## 最终验收

完整 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 仅运行一次，期间未额外 relink。文档、架构、Swift 格式、构建、437 项 Swift 测试及前三个进程脚本通过；在 verify_process 的 LAN check-config 旧断言（漏新增 businessDay 字段）停止。修正该断言后，不重跑完整命令、不重新构建，以同一批二进制从 verify_process 起按 verify.sh 顺序继续剩余脚本，37 个续跑脚本全部通过，合计覆盖 verify.sh 的全部 40 个后端脚本；完整命令没有第二次运行。精确午夜使用注入时钟的真实 SQLite writer；重启/HTTP/恢复使用真实进程，未修改宿主时钟。所有请求仅发往本机 fake provider，没有 Linux 构建或真实提供者验收。

## 相关文档

[设计](proposal.md) · [任务](tasks.md) · [用量规范](../../reference/specs/usage.md)
