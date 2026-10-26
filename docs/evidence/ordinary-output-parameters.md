# 普通输出关联与请求参数验证

> 2026-10-26：输出多视图关联与请求参数形状校验已随[开放协议透传](../changes/open-protocol-passthrough/proposal.md)移除，`verify_output_views.py` 不再存在；本页仅为当时证据。

日期：2026-10-24。产品代码基线9dd0d07；由主Agent实现、自查提交后集中review并修复。行为见[协议](../specs/protocol.md)，外部固定来源及能力边界见[对照矩阵](text-protocol-matrix.md)。本页只保留验证依据，不代替[当前状态](../../STATUS.md)。

## 核查方法与关键结论

- 输出测试从独立字面量样例构造真实HTTP/JSON/SSE、HTTP→WS及native WS，覆盖两轮完整历史、Unicode/前缀增长、created/in_progress、part/delta/done/最终窗口、function/custom与reasoning；不使用本项目响应生成器推导预期。
- 正向接受合法稀疏关联、nullable展示元数据及可选reasoning内容省略；负向覆盖身份/索引/类型/工具调用/参数/内容/密文冲突、缺项、重复与晚到增量。检查精确派发、冲突事件不提交/不建立新绑定、可信usage仍settled failed；没有终态证据仍unknown。WS reader可更早拒绝非法关联，不能强求所有层返回相同细分码。
- 参数测试实际捕获上游wire，分别选择普通Responses/订阅契约，检查支持字段保留、JSON/SSE适配、数值/枚举边界、下游不能改契约及拒绝零attempt/零握手/零create。可信配置另测订阅不可降级与池不可覆盖。
- 集中review修复了两条独立入口遗漏：账号池native首轮原先在建账后才校验参数；稀疏工具增量新增call_id原先未即时检查重复。前者补8种首轮及成功后的拒绝socket检查，后者补冲突增量不转发/不绑定及unknown账本检查；普通文本/摘要完整part生命周期正向另验。
- 账号池合成上游检查普通HTTP实际stream=true/store=false及array输入；固定身份的禁用/刷新继续由独立compact及native续接验证，不以普通HTTP新请求假装连接缓存续接。

## 验证命令与边界

定向入口为`python3 scripts/verify_output_views.py --binary <binary>`及`python3 scripts/verify_request_parameters.py --binary <binary>`，也已纳入`./scripts/verify.sh --backend`和Docker verification的无网络阶段。macOS arm64已执行`CODEXONE_BUILD_JOBS=4 ./scripts/verify.sh --backend`，退出0：Swift 205项；输出视图HTTP 88/WS上游168，共256次；参数314次；既有文本HTTP 73/WS 128，共201次。完整后端入口包括格式/文档/架构、持久化/维护、协议/WS/代理/扩展、图片/压缩、Key/账号配置及合成切回检查，均通过。

Linux amd64执行`docker build --platform linux/amd64 --target verification -f deploy/Dockerfile -t codexone:output-contract-verify .`，退出0：单并发release构建与剥离后的程序通过Docker verification全部无网络socket/维护检查，包含相同201次文本、256次输出视图及314次参数操作。此入口没有运行Linux Swift单元测试或OCI/Compose安装；macOS Swift账号池native首轮补测不冒充Linux同项实测。

实际发布候选5f7efc1（产品代码仍为9dd0d07）另执行`python3 scripts/verify_installation.py --image codexone:desktop-real-test`，退出0：实际amd64 OCI/Compose安装、非root/只读运行、SPA/认证/Key持久化、锁、v5备份迁移及重启通过；未运行浏览器扩展。runtime与verification程序SHA-256相同，均为`276b551c42d8a19f5465837b2f651067211637d71b8219126a39c798c89bc0c8`。本机忽略目录`artifacts/desktop-real-chain/`保留源码归档、实际程序、release及manifest；runtime不可变镜像为`sha256:b36f6d6ac424ff6ad493be764dad7fe1fc9abbe9dd4e8ae3f98865a780ec403e`。

本轮完成一次集中review及相关回归；过程提案/任务/验证日志已归纳回本页与规范，原记录由Git追溯。

上述普通输出/参数修复阶段仅使用临时loopback无凭证上游与合成正文，当时未部署、推送或新增真实订阅调用。后续真实WSS预检证实订阅WS stream的原合成预期有误，不能以原314次通过推导实际订阅WS支持；纠正及失败责任见[接续验证](../changes/subscription-websocket-contract/verification.md)。未重新操作真实Desktop，不把这些结果外推为实际订阅参数、native工具/推理/图片或模型容量已经验收。图片、独立compact及流式压缩维持独立契约与回归。
