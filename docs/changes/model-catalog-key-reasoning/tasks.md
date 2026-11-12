# 模型目录与 Key 推理强度任务

跟踪目录刷新、模型启用和 Key 推理档位授权的实现与验收。

- [x] 核对现有 Key 候选来源、模型 profile 档位字段、请求解析与持久准入入口。
- [x] 检查本机 Codex 缓存中的目录形态。观察到档位和默认档位；该缓存的条目缺少现有 profile 导入器所需的非空 `base_instructions`。验证日期为 2026-11-12，范围限本机缓存和仓库源码。
- [x] 核对 Codex CLI 的模型发现调用。客户端通过提供者认证发送带 `client_version` 的 GET models 请求；这是实现参考，账号端实际响应待验收。[Codex CLI 源码](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/models.rs)
- [x] 2026-11-12，用本机 Codex 的订阅登录和已安装客户端版本执行只读目录请求。响应包含档位、默认档位和完整 profile 字段。合成账号验证刷新失败保留候选。
- [x] 交付手动刷新、目录审核与启停、版本冲突处理，接入 Key 表单和生效目录。合成网关验证持久化和重启。
- [x] 交付每模型的 Key 档位策略、目录过滤和持久准入。合成 HTTP 与原生 WS 验证允许、拒绝和缺省；compact 使用同一请求模型校验。
- [x] 保留旧 Key 和省略新增字段的更新语义，增加 schema v16 和目录 revision 核对，同步能力规范。
- [x] Chrome 验证桌面和 390px 模型启用、编辑 Key 和档位保存流程。
- [ ] 用已部署网关验证真实 Codex 客户端的目录采用和受限档位执行。

## 相关文档

[提案](proposal.md)
