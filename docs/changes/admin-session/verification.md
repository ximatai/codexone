# 管理会话验证

日期：2026-10-31。平台：macOS arm64、本机 Chrome；全程合成数据及 loopback 服务。

## 覆盖

- 可控单调时钟验证空闲 24 小时边界失效、持续活动续期、7 天绝对截止及剩余 Cookie 秒数；响应生成时重算 Max-Age，超截止为 0。
- 重启/重新 bind 失效、退出撤销、16 会话容量与原 Cookie 替换；Host/Origin/CSRF/混合认证规则保持。
- 缺失、错误、大小写不同用户名与错误密码均为相同认证失败；未知字段拒绝。基线无独立登录失败次数限速，保持既有连接数、并发数、期限及响应边界。
- Chrome 检查标准 form、默认 admin、name/autocomplete、密码类型、统一错误提示、不写 localStorage/sessionStorage；失败后清空输入。
- 独立 subagent 只读评审后修正业务错误响应续期与慢响应 Cookie 截止问题；不改变 headless 凭证路径。

## 标准入口与补验

| 命令 | 退出码 | 耗时 | 结果 |
|---|---:|---:|---|
| `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 1 | 69.24 秒 | 文档、架构、Swift 格式与构建通过；287/288 项 Swift 测试通过，既有登录夹具缺 username |
| `swift test --disable-sandbox --no-parallel -j 12 --filter accountManagementUsesRealAuthGuardsAndVerifiedSocketFlows` | 0 | 22.59 秒 | 补齐合成夹具后该项通过，288 项 Swift 测试均已通过 |
| `./scripts/verify.sh --web --chrome` | 1 | 59.49 秒 | lint/格式/类型/构建、Vitest 134 项及 Chrome 33 项通过；1 项要求失败后清空密码框 |
| Chrome 登录与新增界面定向补验 | 0 | 7.55 秒 | 恢复失败清空后，登录失败提示与新增会话/推理界面共 2 项通过 |
| `npm test`（前端 API 增补后） | 0 | 6.21 秒（测试报告） | 135 项通过；lint/类型/构建另行通过 |
| `python3 scripts/check_docs.py`（最终文档） | 0 | 0.49 秒 | 221 篇 Markdown 的入口、链接和变更记录检查通过 |

后端剩余 33 个标准协议脚本按 verify.sh 原顺序续跑，退出 0，耗时 475.22 秒；包含管理会话、参数透传、Images、恢复/存储、WebSocket 与账户失败路径。请求参数脚本覆盖 239 个合成操作。前端最后一次构建退出 0，耗时 1.29 秒。

首次公共依赖下载停滞，构建改用本机 SwiftPM 缓存中锁文件指定的相同提交；临时镜像配置不入库，Package.resolved 未改。首次临时镜像的包标识问题修正后，独立构建退出 0（122.67 秒）。失败后只定向补验失败检查，后端未执行部分按标准入口顺序续跑。

## 边界

未跑 Docker/Linux，未访问部署实例或真实订阅。浏览器凭证保存仅验收可识别表单结构，不声称已测试浏览器自身的保存弹窗。独立失败次数限速如需新增，由主 Agent 另开行为变更。STATUS.md 未改。
