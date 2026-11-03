# 业务日与首页面板验证

本记录仅含合成数据。本机 macOS 27.2 arm64、Apple Swift 6.4.2、Node 26.13.0、Chrome；不代表 Linux、真实订阅或部署验收。

## 业务日

- `swift build -j 12` 成功。首次依赖缓存读取失败，复制本机缓存至当前工作树后构建；未访问其他工作树。
- `swift test -j 12 --filter businessDay`：值类型 floor/溢出、配置错误、−12/+14、当地午夜与 UTC 午夜限额、事务最终窗口、偏移重启、UTC 汇总映射与恢复冻结通过。
- 用量/Token/恢复相关定向回归通过；完整后端验证待最终运行。
- `python3 scripts/verify_business_day.py --binary ... --previous-binary ...`：真实新/旧二进制、独立临时库、fake provider；配置退出78、限额429且不 dispatch、重启重投影、恢复/核对和普通库回退通过。旧二进制由本分支变更前源码在同一工作树内临时构建，完成后源码已还原。
- 旧版能读 business-day-* 历史执行，按 UTC 准入时间计 Token；非 UTC 恢复核对截止早于旧 UTC 最低截止时，旧版拒绝恢复记录，已实测。见[回退指南](../../guide/backup-upgrade.md)。
- web lint、format:check、208 项单元测试通过；Chrome 1440/390px 业务日日期/查询/布局通过，合成截图在忽略的 artifacts/business-day 下并已目视核查。

事务时间修复已采用：store.admit 返回事务最终 admission，coordinator/context 使用返回值；账号池复用同一事务返回值。异常执行也一次取 now。SQL 只有日表达式 helper 持有偏移算术；rollUp、schema、滚动时长与 UTC 小时网格未改。

## 最终验收

面板和最终完整命令结果待补入。完整 backend 仅在最后运行一次，期间不 relink。精确午夜使用注入时钟的真实 SQLite writer；重启/HTTP/恢复使用真实进程，未修改宿主时钟。

## 相关文档

[设计](proposal.md) · [任务](tasks.md) · [用量规范](../../reference/specs/usage.md)
