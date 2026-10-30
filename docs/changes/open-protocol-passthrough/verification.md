# 开放协议透传验证

## 2026-10-30 Linux amd64 出口

候选 a8a3e1b（含模型目录透传与 Key 无限额）：macOS arm64 宿主经 Rosetta 运行 Docker，依赖经按 `Package.resolved` revision 预取的本地镜像构建上下文；`docker build --target verification` 退出码 0，release 构建及全部 verification 脚本 PASS。runtime 镜像在本机构建后上传，服务器不编译、不拉取基础镜像。

## 2026-10-30 真实 Desktop + 真实订阅

部署：用户服务器上的隔离测试实例（独立目录/数据卷/管理凭证，数据与管理入口分离的 HTTPS 反代，上游经服务器本机代理），与旧服务并行且未修改旧服务或其路由。订阅账号经管理台全新 OAuth 授权（不复用旧服务 refresh token），授权后默认禁用、人工核对后启用。Key 由旧服务摘要离线导入，仅启用用户选定的一枚（source 模式无限额，三个对话模型，开视觉输入、关图片生成）。

| 检查 | 结果 |
|---|---|
| readiness / 账号观测 | ready 200；账号授权 ready、无认证拒绝；额度观测 fresh 且 allowed |
| 冒烟（临时单模型 Key，日请求上限 3，原文不离开服务器，结束即禁用） | 模型目录 200 且只含授权模型；`/v1/responses` 与 `/backend-api/codex/responses` 流式各 1 次，200、完整终态与 usage |
| Desktop 新会话（用户操作，原 Key，仅改服务地址） | 三个模型对话均成功；视觉模型正确描述用户上传图片；本地命令工具往返成功 |
| 服务端账本 | 当日 17 次准入全部 settled/complete，无 failed/unknown/partial/在途；含 Desktop 自动 warmup 与并行辅助请求 |

服务端日志无错误；早于成功测试的若干 `invalid_api_key` 401 为客户端切换配置期间产生。

未验证：图片生成（该 Key 未开放；需先完成图片模型映射等对齐）、压缩、长任务与中断恢复、多账号路由及容量，以及其他客户端版本。
