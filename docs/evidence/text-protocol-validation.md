# 文本协议验证摘要

日期：2026-10-24。保留已完成验证的依据及重要失败教训，不作为后续任务清单。现行行为见[协议规范](../specs/protocol.md)，外部类型来源见[对照矩阵](text-protocol-matrix.md)，项目状态与准入条件见[STATUS](../../STATUS.md)。

## 最终受测产物

- 归档来源2336499，产品修正17e625b；精确源码、镜像及身份摘要保留在忽略目录`artifacts/usage-metadata/`。
- verification/runtime/隔离服务器程序SHA-256一致：`212442959e048beee378a8a78dfd11cd79cdac4290451cd6d445102a5785d221`。
- verification中的ProviderObservation、改动的协议/代理/图片脚本及独立JSON夹具，与归档源码逐项核对SHA一致。

## 结果与覆盖

| 平台 | 实际验证 | 结果 |
|---|---|---|
| macOS arm64 / Swift 6.4 | `swift test`；普通协议、WebSocket、独立文本契约、Images及压缩脚本，使用实际网关进程/socket | 203项Swift及受影响脚本通过 |
| macOS arm64 | `verify_text_contract.py --binary .build/debug/codexone` | HTTP73/WS上游128，共201次执行通过 |
| Linux amd64 / Swift 6.4.1 | `deploy/Dockerfile`的完整`verification`目标，隔离无网络运行 | exit 0；包括独立201次、代理/扩展/工具/Images及密钥/快照/低盘/迁移 |
| Linux amd64候选镜像 | `verify_installation.py --image codexone:usage-metadata-candidate` | exit 0；私有初始化、非root/只读、SPA/Key持久、锁、旧库备份迁移与优雅重启 |

独立字面量夹具不调用`trial_provider.response_events`生成响应。覆盖JSON/SSE/桥接/native、全窗口两轮、300000字节实际指令回显、稀疏HTTP流、类型/状态/total/response ID/容量正负向、非终态计数、usage扩展无绑定/伪计量且不输出私有值、无重放及停服后持久账核对。超过1 MiB事件拒绝，不能授予执行或计量证据。

macOS早期完整`verify.sh --backend`曾在代理异步读账断言失败，修正等待后分段补跑全部后端脚本；不把该次命令写为一次全绿。最终程序的203项Swift及上述受影响脚本另已通过。

## 保留的失败结论

- **产品收尾竞争：** 修正探针的intent等待后，Linux仍复现完整JSON响应后settled/failed、indeterminate且usage完整。补JSON批写和校验/绑定/提交后的同步成功观察；不改变Core首次结果、计量及unknown语义，本地提交不等于对端已消费。
- **输出隐私与非终态计数：** 初稿直接保留usage扩展未通过私有标识检查；随后增量review发现非终态已知计数可透出错误字符串/对象。改为已知计数逐阶段严格校验、未知metadata隔离且只投影已支持字段；P2复审关闭。
- **跨能力回退：** 新计数规则曾误作用于图片事件，改变已有用量观察时序，Linux Images失败。修正为普通文本专用，图片/独立compact沿原契约；保留可信host计量断言。
- **探针证据来源：** finalizer等待只等待实际intent且有期限；非终态负向只发送错误前缀并核对具体错误码/固定原因，避免把提供者KeyError或后续终态竞争当成目标拒绝；图片非法tool计量在同一终态提供合法host计量，再要求后者保留。没有以删除失败/unknown断言换取通过。
- **构建限制：** 受限Docker VM发生内存不足和控制面迟滞，取消多余构建后顺序完成；未重启/改资源，既有三个容器运行且无unhealthy。取消、失败和旧脚本镜像均不计最终通过。临时命令误写与逐次构建流水由Git追溯。

## 证据边界

SDK数值时间、instructions对象列表和可空原因是独立可复现的兼容差异，不能认定为历史某笔真实拒绝的唯一根因。真实调用、失败责任及账本摘要集中在[真实订阅验证](real-subscription-validation.md)，不在这里复制。

本次不证明真实Desktop/原生WS订阅、工具/图片/密文推理、账号池/刷新、所有订阅参数组合、普通输出多视图一致性、M5恢复或目标弱宿主容量，也不构成平台接入许可。已完成的提案和任务清单由Git追溯。
