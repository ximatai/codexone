# 请求推理强度与服务档位验证

日期：2026-10-31。平台：macOS arm64、本机 Chrome；全程合成数据及 loopback 服务。

## 覆盖

- 合法 none/minimal/low/medium/high/xhigh、未来有界机器值及 32 字符边界；缺失、空字符串、大小写、空格、超长、非字符串（含显式 null/数组/对象）按契约处理。
- 请求 document 与既有 preparedDocument 规则保持；元数据不进入授权或准入判定。请求参数协议脚本增加 JSON/SSE/桥接/native 的 wire 与 admission/outcome 比对。
- 可信终态实际档位有/无、非法值及非字符串；取消先记录结果、下游写失败后，实际档位仍随最终化保留，结果判定不变；非终态不采信档位。
- SQLite 真实读写验证三个接口字段、历史无标记、新请求未指定、精确筛选、合计/小时桶与全参数加游标。default 为普通合法值；不使用筛选哨兵。
- Chrome 验证推理列、灰字“默认 · high”、目录无默认时“默认”、历史“—”、请求/实际档位详情与筛选；1440×900 与 390×844 截图走查，无水平溢出。
- 独立 subagent 只读评审发现的参数计数、default 哨兵冲突、压缩参数漏传及取消/写失败丢实际档位均已修正。
- 原生 Images JSON 与 SSE 同样观察请求/实际档位；HTTP 与 WebSocket 两模式协议补验通过，覆盖原字节透传、multipart、用量、失败/未知执行与容量；对应 Swift 单测与重新构建通过。
- 同步控制面、用量与协议规范；仅扩展现有 JSON，不改 schema、不补写历史。

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

未跑 Docker/Linux，未访问部署实例或真实订阅；模型默认值是当前可信目录说明，不推断历史实际参数。Linux verification 留给主 Agent。STATUS.md 未改。
