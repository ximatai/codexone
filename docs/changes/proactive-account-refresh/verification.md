# 账号访问凭证提前刷新验证

日期：2026-10-31。平台：macOS arm64；仅合成提供者、临时SQLite与loopback socket，无真实订阅调用。

## 覆盖

- 注入时钟检查901/900秒的后台边界、301/300/1/0秒的dispatch与观察边界；周期队列并发等待者共享一次刷新，版本只递增一次；disabled不刷新；ready且已过期仍可后台恢复。
- enabled/draining提前刷新：可信未完成失败保持ready、同版本，下周期成功；明确拒绝requires_auth，旋转不明auth_uncertain。loopback真实连接拒绝验证安全结束intent，不把一般超时或响应丢失当未完成。
- 实际池dispatch在5分钟内先等待共享刷新，失败不派发、不跨账号刷新；窗口外使用旧版本直接派发。既有持久准入/取消/旋转未知与SIGKILL屏障由完整后端入口覆盖。
- 管理HTTP返回两个时间字段；最近提交审计存在时为整数、缺失时null，显示名/模式不改变该时间；响应断言不含合成access/refresh/id token及内部字段。
- Vitest覆盖时间字段校验、本地时间/相对时间/null；Chrome在1440×900操作账号详情并断言新字段；已检查截图，无遮挡。只读subagent review发现已过期账号路径回归，修复并新增定向回归后验证。

## 数据来源

`accessExpiresAtUnixSeconds`：v9仅在加密凭证中保存到期，没有可靠非密文元数据。管理列表不扩大瞬时明文处理范围，不解密，返回null。前端仍支持未来可靠数字来源及null展示。

`credentialUpdatedAtUnixSeconds`：现有account_events中create_verified、reauthorize_verified、refresh_commit的最大at_epoch；与凭证写入同事务提交，不取刷新开始、失败、显示名或模式修改时间。审计缺失时null。不新增schema，不输出令牌内容、摘要或信封。

## 执行记录

定向迭代：`swift test --disable-sandbox -j 12 --filter 'proactiveRefresh|dispatchWindow|accountPoolRefresh|preparedDispatch|observationJoinsExistingRefresh'`通过9项（Runtime 7、Adapters 2）；`swift test --disable-sandbox -j 12 --filter 'refusedOAuthConnection|accountPoolOutsideFive'`通过2项。前端`cd web && npm test -- --run src/features/account-management/AccountManagement.test.tsx src/features/account-management/api.test.ts`通过19项（Vitest报告2.24秒）。`python3 scripts/verify_admin_round2.py --binary .build/debug/codexone --probe .build/debug/ExecutionProbe`通过管理HTTP合成验证。定向Swift/HTTP总耗时未单独计时。

迭代中曾因新增store端口未补测试代理、测试缺少testable import而编译失败；首次连接拒绝测试揭示单目标连接失败为IOError，补充仅限ECONNREFUSED的可信分类后通过；旧过期fixture的失败预期已改为5分钟内仍有效凭证。以上均在最终完整入口之前修复。

| 命令 | 退出码 | 耗时 | 关键结果行 |
|---|---|---|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | 503.37秒 | Swift 40+44+3+158=245项通过；`PASS: account SIGKILL after_commit; encrypted credentials, durable refresh state and conservative restart`；`PASS: display-name HTTP authorization, validation, CAS, mode preservation, restart and clear`；最后合成cutback验证通过 |
| `./scripts/verify.sh --web --chrome` | 0 | 30.92秒 | `Test Files 18 passed (18)`；`Tests 74 passed (74)`；`6 passed (23.5s)`；lint/format/typecheck/build通过 |
| `python3 scripts/check_docs.py` | 0 | 0.07秒 | `PASS: 186 Markdown documents, required entries, local links and change artifacts.` |

完整入口各运行一次并通过，没有重复已通过入口。

## 边界

未运行Docker/Linux、未访问部署、未调用真实订阅、未push或开PR。Linux verification、部署与真实凭证版本递增确认由主Agent负责；合成结果不代表真实提供者保活验收。
