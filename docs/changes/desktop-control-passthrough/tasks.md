# 任务：Desktop 辅助控制接口透传

契约见 [proposal](proposal.md)。

- [x] 路由允许列表：`/backend-api/codex` 下列出的方法与路径，以及 `GET /backend-api/wham/agent-identities/jwks`；未列出的路径仍返回 404，且无上游调用
- [x] `analytics-events/events` 本地返回 202 空 JSON，不转发
- [x] Key 认证在派发前完成；控制舱壁（全局 8、每 Key 4，超出时 429）；账号选择沿用亲和提示，单身份使用其上游 base；单次请求、不重放
- [x] 请求正文原字节转发（8 MiB，计入全局请求体预算），保留查询串与 Content-Type；响应原样回传（16 MiB 上限，超出返回 502）
- [x] 头部策略与 Responses 一致；提供者错误按 P27 透传，429 设置冷却，401 计入健康状态
- [x] 期限：60 秒（memories 为 300 秒）；超时返回 504，记为结果未知
- [x] 有界结构化日志：不含正文、查询串或头部；realtime 只记录状态与耗时
- [x] 合成上游验证脚本与失败路径测试；同步 protocol 规范与开发文档
- [ ] 部署后真实验证：在 Desktop 中执行独立搜索
