# 业务日与首页面板验证

本记录仅含合成数据，不代表 Linux、真实订阅或部署验收。最初开发验证使用 macOS 27.2 arm64、Apple Swift 6.4.2、Node 26.13.0、Chrome；变基后的本轮环境与结果另列于下方。

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

## 变基前验收（历史记录）

完整 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 仅运行一次，期间未额外 relink。文档、架构、Swift 格式、构建、437 项 Swift 测试及前三个进程脚本通过；在 verify_process 的 LAN check-config 旧断言（漏新增 businessDay 字段）停止。修正该断言后，不重跑完整命令、不重新构建，以同一批二进制从 verify_process 起按 verify.sh 顺序继续剩余脚本，37 个续跑脚本全部通过，合计覆盖 verify.sh 的全部 40 个后端脚本；完整命令没有第二次运行。精确午夜使用注入时钟的真实 SQLite writer；重启/HTTP/恢复使用真实进程，未修改宿主时钟。所有请求仅发往本机 fake provider，没有 Linux 构建或真实提供者验收。

## 变基后基线与评审收尾（2026-11-03）

- 已从原业务日分支变基到本地已获取的 `origin/main`：`abdfd40`（含 v0.26.9-rc.2、上传完成后的首响应计时及分片调整）。仅操作当前工作树与 `codex/business-day`；未 fetch、push、开 PR 或发版，未增加 CHANGELOG 版本段。
- 冲突仅在 STATUS、活动提案目录与分片清单；保留双方条目。main 的上传计时、超限预检/1009/HTTP 回退实现和两个验证脚本无差异；本轮完整后端验证继续覆盖它们。
- `admitTransaction` 先调用 `withWindow(window)`，该方法无条件复制并设置 `window`，因此后续 `command.window == window` 恒真，整个旧 UTC/最终窗口的 OR 判断恒真。现直接以事务时钟计算并替换最终窗口，移除该冗余判断；恢复冻结、Key revision/priming 保护保持。
- 本轮实际环境：macOS 27.2 arm64、Apple Swift 6.4.2、Node 22.22.0、Chrome。Node 26.13.0 的下载不完整，准备命令未阻断后续入口，前端实际回退使用本机 Node 22；低于项目要求，不能视为 Node 26 环境验收。未为切换 Node 重复运行本轮检查。
- `./scripts/verify.sh --web --chrome` 仅运行一次并成功退出：内含 `npm --prefix web run lint`、`format:check`、`test` 各一次，214 项单元测试、生产构建（含 typecheck）及 64 项 Chrome 测试通过。覆盖业务日与首页面板的大屏/390px 交互。生成的文档截图已恢复，本次无图片变更。

- `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend` 仅运行一次，成功退出，无失败续跑、额外构建或 relink：文档、架构、Swift 格式、构建、439 项 Swift 测试及全部 41 个进程脚本通过。其中超限矩阵 96 秒、上传计时矩阵 72 秒；业务日与首页面板真实二进制/fake provider 验证分别 3 秒、2 秒。上一版本二进制的可选回退演练本轮未重复，仍以此前记录为证。
- 依 `PASS: scripts/... (Ns)` 按 `scripts/backend_shards.json` 汇总，本机四分片纯脚本时间分别为 **164 / 312 / 139 / 133 秒**；新增两项均在分片 2，合计 **5 秒**（未加入前 307 秒）。最长分片为 312 秒，距 Verify 的 480 秒作业上限剩 168 秒；没有新增脚本使分片逼近上限的证据，故保留 main 的分片调整与新增脚本归属，不削弱覆盖。`backend_shards.py --check` 确认 41 项各归属一个分片。计时为本机串行 debug 脚本的秒级采样，不含 CI 初始化/下载，也不是 Linux CI 或优化二进制耗时保证；CI 的实际余量仍待评审者观察。
- 最终文档修改后运行 `python3 scripts/check_docs.py`，检查差异与新增文件；未增加个人路径、私人域名、凭证或真实数据。完整入口已含的 lint、format:check、test 不再额外重复运行。
- 本轮仅 macOS 和本机合成 provider；未访问其他工作树、主检出、SSH、部署实例、真实订阅或 OpenAI 接口，未构建 Linux。剩余验收边界为项目要求的 Node 26 环境与 Linux CI；版本由评审者决定。

## 相关文档

[设计](proposal.md) · [任务](tasks.md) · [用量规范](../../reference/specs/usage.md)
