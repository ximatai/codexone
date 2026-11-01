# 任务：账号授权失败原因

契约见 [proposal](proposal.md)。

- [x] 建立提案，确认 I15/I16 与 A12 的增量和兼容约定。
- [x] 后端类型化分类、Runtime 单次安全日志及合成失败路径验证。
- [x] 前端中文解释、未知代码回退和大屏/窄屏验证。
- [x] 同步规范与 CHANGELOG Unreleased，执行要求的验证并记录实际结果。

## 验证记录

2026-11-01，本地 macOS 27.2 / arm64，Swift 6.4.2、Node.js 22.22.0、npm 10.9.4。Node 低于贡献指南的 22.23.0；保留现有环境与依赖，实际检查结果如下。不访问真实订阅、部署或 OpenAI 端点，不执行 Linux 镜像构建；合成结果不代表真实提供者/TLS 兼容。

- 文档、Swift 格式与架构检查通过。
- 授权定向 Swift 测试通过：设备码等待/取消/到期、回调、PKCE/nonce/JWT、身份及 CAS；新增 18 种设备失败场景与 4 种回调场景，断言每次失败仅一条 warning、固定字段与空 error，不含合成秘密。覆盖存储拒写及重复绑定，失败不改变原账号，不重放兑换。
- `npm --prefix web run lint`、`format:check`、`test`：通过，180 项单测；`npm --prefix web run build`（含 typecheck）：通过。
- Chrome 的设备码原有流程与新增失败提示在 1440×900、390×844 通过；最终文案版本再跑 2 项失败流程通过，合成截图在忽略的 `artifacts/auth-failure-reasons/`，已目视检查。覆盖未知代码回退、回调输入清除、失败结果保留、明确关闭、无持久缓存；单测另验证已提交回调不再受页面等待倒计时取消。
- 最终 `CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend`：仅执行一次，通过；329 项 Swift 测试与 33 项进程、协议、存储及管理验收脚本全部通过。

schema 仍为 v10，无数据迁移。客户端须接受新增 failureCode；回调 POST 的 invalid_grant 分类兼容影响见提案与 A12，设备码 403/404 pending、一次性消费、取消与关闭责任不变。

## 相关文档

[变更约定](../README.md)
