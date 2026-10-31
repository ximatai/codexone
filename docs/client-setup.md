# 客户端配置

适用于 Codex CLI 与 Codex Desktop。从旧服务迁移时只改 `base_url`，其余保持原样。

```toml
model = "gpt-6.1-sol"
model_provider = "codexone"

[model_providers.codexone]
name = "openai"
base_url = "https://<网关域名>/backend-api/codex"
wire_api = "responses"
supports_websockets = true
env_key = "CODEXONE_API_KEY"   # 环境变量中放 CodexOne Key
requires_openai_auth = false
http_headers = { "x-openai-actor-authorization" = "codexone" }
```

| 配置 | 作用 |
|---|---|
| `name = "openai"` | 客户端按官方 provider 处理，启用远程压缩与独立搜索 |
| `env_key` | Key 通过环境变量传给网关；不需要也不应使用 ChatGPT 登录 |
| `requires_openai_auth = false` | 必须为 false，否则下面的头失效 |
| `http_headers` 中的 `x-openai-actor-authorization` | 客户端本地开关：有非空值才声明内置生图（`image_gen`）与独立搜索工具，值任意 |

## 注意

- `http_headers` 必须写在 `[model_providers.<名称>]` 段内。TOML 中一行属于其上方最近的段，写在文件末尾会被其他段吸收并被忽略。
- 改配置后需彻底退出 Desktop（含托盘）并新开会话，工具在会话开始时注册。
- 只把带门控头的 provider 指向 CodexOne 或同类网关。网关不会把这个头转发给上游提供者（见[协议规范](specs/protocol.md)）；不要把带这个头的配置直接指向官方端点。
- Key 需开通对应图片模型（如 `gpt-image-2`）才能生图。用 Key 连接时客户端使用内置模型目录，不读取网关 `/models`。

## 排查

内置生图不可用时，在新会话中让模型“不执行操作，列出全部工具名，包括 exec 中声明的嵌套工具”：

- 列表中没有 `image_gen__imagegen`：客户端没有声明工具，请检查上面四项配置，请求不会到达网关。
- 有该工具但调用失败：查看管理台用量中 `gpt-image-2` 记录及其失败原因。
