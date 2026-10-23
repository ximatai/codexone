# 受控真实订阅验证与责任账

日期：2026-10-23—24。本页记录已发生调用，不构成新的调用授权；当前调用边界只见[STATUS](../../STATUS.md)。最终程序及本机/Linux检查见[文本协议验证](text-protocol-validation.md)。

## 验证条件

用户授权使用既有身份进行短文本验证。独立私有loopback实例、单一模型/单并发，经既有Clash，仅取有效access快照；不调用refresh、不修改旧账号/服务，不读取用户文件或执行工具。逐轮核对终态、用量及持久账后才继续，首错停止，无自动重放。TLS或额度GET仅为预检，不计生成通过。

派发前同步私有调用记录，结束后保留SQLite与脱敏报告，核对服务器/本机副本摘要；只清除临时凭证。最早探针误清理原SQLite的缺陷和未知责任必须继续披露，不能伪造回填。

## 八次生成及证据

输入/输出列为可信token计数；“无证据”不能按零消耗处理。

| 次数 | 程序来源 | 实际结果 | 持久状态/计量 | 保留证据SHA-256 |
|---|---|---|---|---|
| 1 | 56600c0 | upstream_rejected；缺细分诊断，不能唯一归因未验输出上限等请求差异 | unknown/failed，无可信usage | 原SQLite误清理，仅保留脱敏外部记录 |
| 2 | 75ee891 | invalid_upstream_content_type；未保存原媒体值，不能推断为缺头/HTML/账号异常 | unknown/failed，无可信usage | `29e8e825cf5c6fa5b63caf861fed22051a9a6a01e8b893d2f49da72dd881c599` |
| 3 | afe1244 | 实际观察缺媒体类型；HTTP200/SSE未完成，漏记安全错误码，不能推断具体事件 | unknown/failed，无可信usage | `8edd9ba8e99e4e1b78b3a3eaa1078062ff221b807ca9dfe43ef9575bb779694b` |
| 4 | 253bcda | 收到文本后unsupported_upstream_event，固定reason=upstream_event；具体事件未留存 | unknown/failed，无可信usage | `bcbcb3152fee5d3d54acba2f8f41ab6f72c207b818b99e79a9b3313508bb8da4` |
| 5 | 3b2c4d8 | 收到文本后unsupported_upstream_object，未有对象细分分类 | settled/failed，51/11完整 | `a9a9edaf420b9f2701843f4e45170c532f4f87c765bc51f213cb06135010a6e6` |
| 6 | 04543be | unsupported_upstream_object，固定reason=upstream_usage_container；具体附加字段/容量未留存 | settled/failed，51/11完整 | `858076ea24cde8a3be16180e63b5059e9533724293e3e080aea3a20c41b3d60c` |
| 7、8 | 2336499 | HTTP200、各唯一response.completed；合成校验码及第二轮全窗口复述均匹配 | 两笔settled/succeeded；51/11、82/11完整，cached均0 | 共用库`2e4bde74c1bce5ac2c8e7e2fc58ecbdaf0c6a93da2c402af9e0f948b7abf8332` |

合计4笔历史未知、2笔完整计量失败、2笔成功。原5份历史库及最终共用库保留服务器/私有本机副本；最早一笔仅外部记录，不能宣称全部原库齐全。最终两笔新未决0不消除历史未知责任，后续成功不冲销失败或未知。

## 最终两轮及清理核对

- HTTP/SSE，`stream=true`、`store=false`；第二轮回送首轮完整输出窗口，先核对第一轮settled/succeeded与完整计量，再派发第二轮。未设置未经该订阅验证的max_output_tokens，不承诺硬token上限。
- 第一轮input51/output11/total62，第二轮82/11/93；合计input133/output22/total155。响应与账本一致；零列表价格仅为未校准测试估算，不是实际费用结论。
- 两轮实际观察：整数型数值时间、字符串instructions、null incomplete_details，无encrypted reasoning。不得把独立SDK新形态或密文续接写成这次真实观察。
- 最终程序SHA-256为`212442959e048beee378a8a78dfd11cd79cdac4290451cd6d445102a5785d221`，验证/runtime/服务器一致。最终精确源码、镜像与私有报告保留在忽略目录`artifacts/usage-metadata/`。
- 隔离实例正常停服回收，访问/管理秘密已清除、日志无凭证。最后核对旧服务healthy、身份/配置/运行指纹未变，原公开合成入口前后ready；无公开切换、推送或发布。该记录不代表持续巡检。

## 范围限制

通过范围仅为选定模型/参数的HTTP全窗口文本两轮；不覆盖Desktop界面、真实native WS、工具/图片/密文推理、池路由/刷新、JSON/store等其他组合或M5。早期缺失的媒体、事件和字段证据不能事后补写唯一根因。旧预算调整、逐次编译和探针开发过程由Git追溯，不能当作后续继续调用的计划。
