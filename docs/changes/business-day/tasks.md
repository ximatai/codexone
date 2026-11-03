# 业务日与首页面板任务

[批准设计](proposal.md)。仅当前工作树/分支、本机合成数据；不访问其他工作树、部署、订阅或真实上游，不 push/PR。schema v11 不变。

## 1. 设计修订（首个提交）

- [x] 按评审简化设置、SQL、UTC 汇总映射、切换、恢复、API 和回退。
- [x] 保留完整依赖清单，首页缓存率按已观测请求计算，失败链接仅使用摘要日期。

## 2. 业务日（独立提交）

- [x] Core 值类型、严格整小时设置、启动日志与统一组装。
- [x] 网关/priming/异常执行窗口、事务最终时间及旧窗口恢复比较；说明最终实现选择。
- [x] 清单中 writer/reader/headroom/attention 全部日边界与 usage_daily 读取；rollUp/schema 不变。
- [x] 恢复/首次核对冻结，继承截止不缩短，不存定义。
- [x] API 元数据与日 end 校验，web 服务端日期/趋势/限额文案；到期 UTC 不变。
- [x] 合成测试：当地午夜准入及限额、UTC 午夜不重置、重启改 offset、汇总映射、恢复冻结、非法值、−12/+14、缺省 UTC；进程边界用真实 binary/fake provider。
- [x] 合成数据库核查上一版本的业务日窗口兼容及回退实际行为。
- [x] 更新规范/配置/恢复指南/STATUS，记录验证与局限，不改 CHANGELOG 版本标题。

## 3. 首页面板（叠加独立提交）

- [ ] 摘要 input/cached 与无用量提示；Token 复用治理投影。
- [ ] 精确 outcome=failed 全链路，排除准入前诊断，保留 failedOnly 原意。
- [ ] 今日活跃未归档、最近活动排序、六列、名称详情与非零状态、失败 20/5/20% 规则。
- [ ] 失败链接用摘要起止日期；缓存仅无已观测输入时为 dash，真实 0% 保留。
- [ ] 单元与合成浏览器大/窄屏关键操作、刷新/失败/空态；同步规范。

## 4. 最终验证

- [ ] macOS `swift build -j 12` 与定向后端测试。
- [ ] `python3 scripts/check_docs.py`。
- [ ] web lint、format:check、test 及 `./scripts/verify.sh --web --chrome`。
- [ ] 最后仅一次 `./scripts/verify.sh --backend`，运行期间不 relink。
- [ ] 检查差异/新增文件，提交单一关注点，报告平台、结果、局限、偏离与未提交工作。

## 相关文档

[设计提案](proposal.md) · [验证约定](../../development/verification.md)
