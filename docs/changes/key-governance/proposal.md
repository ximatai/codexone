# 多主体与 Key 治理切片

## 目标与约束

按用户 2026-10-22 指示保留 M2 Desktop UI 与恢复契约缺口，先推进独立 M3。本切片实现 I01/I03/I04/I05、U01/U02/U06 和 A01/A06 的 Key 治理部分：一个受控上游、多主体及多 Key，模型目录与实际执行取相同交集；每个新 HTTP 请求/WS turn 认证，准入事务再次检查 Key revision/enabled/principal，普通撤销不取消已准入执行且不抹除结算。轮换替换同一 Key 标识的验证材料并递增 revision，旧凭证失效，主体、计数、预算与历史归属保持，避免通过轮换重置限额；对象仍按 principal/namespace/identity 归属，不能因换 Key 跨主体。

## 实现与管理入口

SQLite v2 在原串行有界队列上保存 Key 摘要、稳定主体、权限、限额与有界变更审计；v1 显式升级，attempt/binding 保持。Key 使用系统随机 256 bit，仅创建/轮换响应返回一次，库内只有 SHA-256。每 Key 的 UTC 日请求/估算预算和生命周期 active/unknown 暴露在原准入事务中检查，全局/主体/身份治理仍保留。

新增显式 managed Keys 模式，无 legacy Key 回退；原单身份注入模式保持兼容。受控提供者身份与命名空间不因 Key 轮换改变。最小管理 API 仅 loopback，独立私有文件注入管理员高熵 Bearer，常量时间比对；不使用浏览器 session/cookie，拒绝任何 Origin/Sec-Fetch-Site 及数据 Key。管理错误和日志不含请求正文/凭证，secret write-only，元数据有界分页，更新/轮换 CAS。后续浏览器 UI 必须另验安全 cookie、同源/CSRF，不能以此替代 I07 的 session 交付。

管理入口由 NIO 监督有界连接、绝对正文读取期限及输出结束；完整小请求交给 Vapor 的管理路由/DTO，不使用其 listener 的未完成流式正文寿命作为资源保证。具体失败证据见验证记录；Core 与 Runtime 依赖方向保持。

## 验收与失败

真实 SQLite 验证迁移、竞争限额、更新/轮换竞争、旧 revision 准入失败、主体验证、历史归属与重启；真实 HTTP/WS 验证管理员认证/Origin 拒绝、目录/执行交集、跨主体引用拒绝、同主体轮换续接、已连 WS 撤销后下一 turn 拒绝、用量仍结算。检查 DB/WAL 和输出无明文 Key/上游凭证。复跑 M2 无凭证后端回归，提交后独立 review、主 Agent 修复复验。

## 排除与数据/回退

不宣称 OAuth/账号池/订阅额度/管理 UI/M3 已完成；不启用真实账号。没有正文缓存或输出恢复变更。schema v2 不可直接用旧二进制打开，旧版本须恢复升级前一致性备份；不原地降级或丢弃 Keys/账本。权限/审计数量和命令队列有界，容量满明确拒绝，不静默删历史。升级必须先一致性备份并显式执行，不在服务启动偷偷升级非空 v1。
