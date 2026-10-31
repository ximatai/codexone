# CodexOne

个人自托管网关：管理自己的 ChatGPT/Codex 订阅账号，为自己的多台设备和工具分别发放 Key，提供权限隔离、用量治理与可靠转发。

[English](README.en.md) · [文档](docs/README.md) · [项目状态](STATUS.md)

## 为什么需要它

- **设备和工具各用一枚 Key**：分别设置模型、视觉输入和图片生成权限，支持禁用、轮换与归档。
- **统一管理自己的账号**：浏览器授权、加密保存凭证、自动刷新与订阅额度观察。
- **看清本地用量**：按 Key 查看请求、token、估算费用与失败原因，缺失用量明确标为未知。
- **可靠转发日常工作流**：Responses HTTP/SSE、WebSocket、预热、压缩、工具、图片生成与参考图编辑；可能已执行的请求不自动重放。
- **可维护的数据与配置**：独立主密钥、快照备份、显式迁移和受控恢复。

## 管理界面

以下均为合成账号、模型与请求，非真实运营数据。

![服务概览](docs/assets/overview.png)

![访问密钥](docs/assets/keys.png)

## 快速开始

**v0.26.1 尚未发布。** 以下 GHCR 镜像在首个版本发布后可用；现在可按[安装指南](docs/guide/linux-installation.md)从源码构建；[发版自动化](docs/development/releasing.md)已就绪，尚待首次发布验证。运行目标为 Linux amd64 Docker Engine，准备 Compose v2、Python 3、本地磁盘和 HTTPS 反代。

从源码目录初始化独立安装目录，镜像必须解析为不可变 ID：

```sh
docker pull ghcr.io/ximatai/codexone:0.26.1
CODEXONE_IMAGE_ID="$(docker image inspect ghcr.io/ximatai/codexone:0.26.1 --format '{{.Id}}')"
python3 deploy/init-install.py ../codexone-private \
  --image "$CODEXONE_IMAGE_ID" --origin https://admin.example.invalid
cd ../codexone-private
# 私下编辑 secrets/pool.json，设置账号可用的模型、能力与估算费率
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py up -d
```

按[TLS 指南](docs/operations/tls-proxy.md)配置 HTTPS 数据和管理入口。使用用户名 `admin` 与私有 `secrets/admin` 中的秘密登录；[授权自己的账号并启用，再创建设备 Key](docs/guide/admin.md)。不要公开秘密或授权回调。没有启用账号时 ready 为 503。

客户端将 Key 放入环境变量 `CODEXONE_API_KEY`，在 Codex 配置中添加：

```toml
model = "<已配置并授权的模型>"
model_provider = "codexone"

[model_providers.codexone]
name = "openai"
base_url = "https://gateway.example.invalid/backend-api/codex"
wire_api = "responses"
supports_websockets = true
env_key = "CODEXONE_API_KEY"
requires_openai_auth = false
http_headers = { "x-openai-actor-authorization" = "codexone" }
```

provider 名称和门控头只是客户端兼容设置，不代表官方授权。配置后重启 Desktop 并新建会话；工具与图片权限细节见[客户端接入](docs/guide/client-setup.md)。

## 系统要求与已知限制

- 容器面向 **Linux amd64**，使用 host network 与本地命名卷，仅监听回环，由宿主 TLS 反代接入；不直接适用 Docker Desktop。模板设 768 MiB 内存上限，这不是最低宿主配置或吞吐承诺。
- 源码开发需要 macOS 15+、Swift 6.4、Node.js 22.23.0 和 Python 3；Linux 源码构建需 SQLite 开发库。见[贡献指南](CONTRIBUTING.md)。
- 单节点、单管理员；多账号路由还需完整验收，不提供支付结算、多管理员 RBAC 或高可用。
- 费用是本地估算，订阅额度是观察值，未知用量不计零；不保证金额/token 绝对封顶。
- 正文/图片恢复缓存尚未交付，不保证任意断线或重启后恢复已有输出。协议与客户端兼容有边界，见[兼容说明](docs/reference/compatibility.md)。

## 文档导航

[安装与配置](docs/guide/README.md) · [管理面板](docs/guide/admin.md) · [备份升级与回退](docs/guide/backup-upgrade.md) · [从 codex-lb 迁移](docs/guide/migration.md) · [常见问题](docs/guide/faq.md)

[运维](docs/operations/README.md) · [接口与规范](docs/reference/README.md) · [架构](docs/architecture/ARCHITECTURE.md) · [贡献](CONTRIBUTING.md) · [安全报告](SECURITY.md)

## 免责声明与风险

CodexOne 是独立非官方项目，与 OpenAI 无隶属关系，也未获得其背书。OpenAI、ChatGPT、Codex 为其各自所有者的商标。

网关会以 **Codex 官方客户端的标识与官方 OAuth 客户端 ID** 访问上游。这可能违反提供者条款、触发风控或导致账号受限；内部端点和协议可能随时变化。使用者须自行确认适用条款、授权与账号风险；技术兼容或 MIT 许可不表示取得提供者服务授权。本项目定位为管理自己的账号与设备，不提供与他人共享订阅的授权。

## 许可证

[MIT](LICENSE)。[来源说明](docs/reference/provenance.md) · [第三方许可](THIRD_PARTY_NOTICES.md)。
