# Key 显示名验证

日期：2026-10-31。范围：macOS arm64、本机合成数据与独立 Chrome 上下文。

## 覆盖

- Key 元数据历史缺字段、显示名边界、清除、CAS 冲突；同名不同 Key 的认证隔离；全量更新、到期设置与轮换保留显示名。
- 当前元数据关联至列表、用量 options/明细/今日摘要、进行中请求；attention 优先显示名。
- 前端显示优先级、按别名搜索、设置与清除、409 刷新、不重放、权限先提交后的显示名失败处理；大屏与窄屏 Chrome 操作及截图走查。
- 前端 subagent 评审的最近请求 JSX、部分成功提示、用量详情主体灰字问题已修正。

## 命令记录

完整前端入口的 lint、格式、类型、构建与 Vitest 100 项通过；Chrome 12 项通过，新增用例的灰字颜色断言与主题值不一致，修正后定向补验通过。截图位于忽略的 artifacts/key-display-name。

| 命令 | 退出码 | 耗时 | 结果 |
|---|---|---|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 518.65秒 | 文档/架构/格式、构建、Swift 260项及全部本机后端合成脚本通过；管理HTTP包含显示名授权、非法输入、409、各用量字段/null、进行中更新与attention |
| `./scripts/verify.sh --web --chrome` | 1 | 约25秒 | lint/格式/类型、Vitest 100项、生产构建通过；原有Chrome 12项通过，新增用例灰字颜色断言失败 |
| `cd web && npx playwright test tests/e2e/key-display-name.spec.ts --project=chrome` | 0 | 5.7秒 | 修正主题颜色断言后定向补验1项通过；1440×900和390×844走查，截图等待抽屉过渡结束 |
| `python3 scripts/check_docs.py` | 0 | 小于1秒 | 203份Markdown、本地链接和变更结构通过 |

首次依赖下载完整Git历史缓慢，改在本worktree的忽略构建目录浅拉取锁定提交，并补齐锁文件对应版本引用；没有变更依赖版本或锁文件。`swift build --disable-sandbox -j 12 --skip-update`预构建通过（编译阶段35.96秒），随后运行上述完整后端入口。原始下载等待/解析失败不计为测试通过。

## 边界

不运行 Docker/Linux 构建、部署、真实订阅调用、推送或 PR。Linux 与部署/别名迁移留给主 Agent，任务第四项不勾选。原生筛选框不能对选项分段着色，显示名与主体名以文本并列。
