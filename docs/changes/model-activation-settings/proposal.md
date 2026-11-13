# 启用模型时配置推理档位

首次启用或重新启用对话模型时，可编辑允许档位和默认档位。复用已启用模型的校验规则，随启用操作一次提交。重新启用预填兼容的原设置，上游档位变化导致原设置失效时要求明确确认。

首次启用按模型 ID 预填公开参考费率，可修改。没有参考价时预填 0。参考价取自 [OpenAI Codex 公开费率表](https://help.openai.com/en/articles/20001415-chatgpt-rate-card-enterprise-token-based-pricing)。重新启用沿用已保存的费率。沿用 schema v18 和既有数据，旧版客户端可继续提交原启用请求。

## 相关文档

[任务](tasks.md) · [管理面规范](../../reference/specs/control-plane.md)
