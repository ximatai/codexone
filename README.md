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

## 选择部署路线

- **局域网（无域名）**：家里或办公室的可信内网，用 HTTP 直接访问，不需要域名、证书和 Nginx，十分钟左右完成。
- **公网或有域名**：需要在外网使用，或者网络不完全可信时，走下方的 [HTTPS 部署](#部署到自己的服务器https)。

## 局域网部署（无域名）

> [!WARNING]
> 局域网模式不加密：管理员秘密、登录会话、Key 和请求内容都以明文在局域网中传输，同一网络里的设备可以截获。只在自己信任的私有网络使用；不要在公共或不可信的 Wi-Fi 上使用，不要用路由器端口转发把它暴露到公网。需要在外面访问时，改用 HTTPS 部署或 Tailscale 等私有网络。详见[局域网 HTTP 风险](docs/operations/tls-proxy.md#局域网-http-风险)。

需要：一台 Linux amd64 服务器，装好 Docker Engine 与 Compose v2、Python 3、Git，并有固定的局域网 IP；以及自己的 ChatGPT 订阅账号。局域网模式从 v0.26.2 起提供。

### 1. 下载并初始化

```sh
git clone --depth 1 --branch v0.26.2 https://github.com/ximatai/codexone.git
cd codexone
docker pull ghcr.io/ximatai/codexone:0.26.2
CODEXONE_IMAGE_ID="$(docker image inspect ghcr.io/ximatai/codexone:0.26.2 --format '{{.Id}}')"
hostname -I   # 查看服务器的局域网 IP，下面以 192.168.1.10 为例
python3 deploy/init-install.py ../codexone-private --image "$CODEXONE_IMAGE_ID" --lan 192.168.1.10
cd ../codexone-private
```

初始化会打印风险提示、管理地址和客户端地址。用 root 执行时加上 `--uid 10001 --gid 10001`。IP 必须是局域网地址（10.x、172.16–31.x、192.168.x、Tailscale 的 100.64–127.x 等）。想只允许某个网段访问，可以加 `--lan-allow 192.168.1.0/24`，一般不需要。

### 2. 配置模型并启动

编辑 `secrets/pool.json`，把 `configure-model-before-use` 换成你的订阅在 Codex 里能选到的模型名，费率不确定就填 0（字段见[配置网关](docs/guide/configuration.md)）。然后：

```sh
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py up -d
python3 compose-install.py ps
```

### 3. 登录管理页面，授权账号并创建 Key

1. 执行 `cat secrets/admin` 取得管理员秘密，在同一局域网的电脑上打开 `http://192.168.1.10:18081`，用户名填 `admin`。页面顶部会一直显示明文传输提示，这是正常的。
2. 在“账号”页添加并授权自己的账号，授权完成后点击“启用”。
3. 在“访问密钥”页为每台设备创建一个 Key，Key 只显示一次，请立即保存。

### 4. 接入 Codex

在客户端设备上把 Key 放进环境变量 `CODEXONE_API_KEY`，在 `~/.codex/config.toml` 中添加：

```toml
model = "<第 2 步配置的模型名>"
model_provider = "codexone"

[model_providers.codexone]
name = "openai"
base_url = "http://192.168.1.10:18080/backend-api/codex"
wire_api = "responses"
supports_websockets = true
env_key = "CODEXONE_API_KEY"
requires_openai_auth = false
http_headers = { "x-openai-actor-authorization" = "codexone" }
```

重启 Codex 并新建会话发一条消息，管理页面的用量里能看到这次请求就说明成功了。以后要改成 HTTPS，见[切换局域网与 HTTPS](docs/guide/linux-installation.md#切换局域网与-https)。

## 部署到自己的服务器（HTTPS）

下面以当前版本 [v0.26.2](https://github.com/ximatai/codexone/releases/tag/v0.26.2) 为例，从零部署到一台 Linux 服务器。全部完成大约需要 20–30 分钟，大部分时间花在 HTTPS 证书和账号授权上。

### 0. 准备

| 需要什么 | 说明 |
| --- | --- |
| 一台 Linux amd64 服务器 | 安装 Docker Engine 与 Compose v2（`docker compose version` 能输出版本）、Python 3、Git。不支持 macOS/Windows 的 Docker Desktop。 |
| 两个 HTTPS 域名 | 一个给客户端调用（下文称**数据域名**，如 `gateway.example.com`），一个给浏览器管理（**管理域名**，如 `admin.example.com`），都解析到这台服务器并有可信证书。 |
| Nginx | 在宿主机上终止 TLS，转发到只监听本机回环的网关。 |
| 自己的 ChatGPT 订阅账号 | 稍后在管理页面里授权。 |

### 1. 下载部署工具并拉取镜像

部署脚本随源码发布，镜像来自 GHCR：

```sh
git clone --depth 1 --branch v0.26.2 https://github.com/ximatai/codexone.git
cd codexone
docker pull ghcr.io/ximatai/codexone:0.26.2
CODEXONE_IMAGE_ID="$(docker image inspect ghcr.io/ximatai/codexone:0.26.2 --format '{{.Id}}')"
echo "$CODEXONE_IMAGE_ID"   # 应输出 sha256: 开头的完整 ID
```

安装固定到这个不可变 ID，之后有人改动 tag 也不会影响你的部署。如需核对镜像来源，见[发版规则](docs/development/releasing.md)；也可以[从源码构建](docs/guide/linux-installation.md#从源码构建)。

### 2. 初始化安装目录

安装目录保存全部私有配置和秘密，必须放在源码目录之外、且尚不存在：

```sh
python3 deploy/init-install.py ../codexone-private \
  --image "$CODEXONE_IMAGE_ID" --origin https://admin.example.com
cd ../codexone-private
```

- `--origin` 填浏览器打开管理页面时的完整地址（`https://` + 管理域名），必须与之后访问的地址完全一致，否则无法登录。
- 用 root 执行时，还要加上运行用户 `--uid 10001 --gid 10001`（任意非 root 的数字即可）；普通用户执行时默认用当前用户。
- 生成的 `secrets/admin` 是管理员登录秘密，`secrets/master` 是账号凭证主密钥，请妥善保管，不要提交到任何仓库。

### 3. 配置可用模型

编辑 `secrets/pool.json`，把示例模型换成你的订阅在 Codex 客户端里能选到的模型名。费率只用于本地估算费用，单位是每百万 token 的微美元，不确定就先填 0：

```json
{
  "models": [
    { "id": "<模型名>", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0 }
  ],
  "reservedMicros": 1000000,
  "executionTimeoutSeconds": 1800,
  "upstreamTransport": "http"
}
```

视觉输入、图片生成和其他字段见[配置网关](docs/guide/configuration.md)。改完后检查配置：

```sh
python3 compose-install.py run --rm gateway --check-config
```

### 4. 启动网关

```sh
python3 compose-install.py up -d
python3 compose-install.py ps
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/health/live    # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/health/ready   # 此时 503 是正常的
```

网关只监听本机：`127.0.0.1:18080` 是数据入口，`127.0.0.1:18081` 是管理入口。还没有启用账号时 ready 为 503，第 6 步完成后会变成 200。之后一律用 `python3 compose-install.py <命令>` 操作，不要直接用 `docker compose`。

### 5. 配置 HTTPS（Nginx）

1. 把 [deploy/nginx-data.conf](deploy/nginx-data.conf) 和 [deploy/nginx-admin.conf](deploy/nginx-admin.conf) 复制到 `/etc/nginx/snippets/`，分别改名为 `codexone-data.conf`、`codexone-admin.conf`。
2. 参照 [deploy/nginx.conf.example](deploy/nginx.conf.example) 在 Nginx 的 `http {}` 中加入两个 server，把 `server_name` 和证书路径换成你的数据域名和管理域名。
3. 执行 `nginx -t`，通过后重新加载 Nginx。

数据域名只转发客户端接口，管理域名只提供管理页面。只想公开数据入口、不想公开管理页面，或需要申请证书，见 [TLS 反代](docs/operations/tls-proxy.md)。

### 6. 登录管理页面，授权账号

1. 在服务器上执行 `cat secrets/admin` 取得秘密，打开 `https://<管理域名>`，用户名填 `admin`。
2. 进入“账号”页添加账号：在自己的浏览器里登录 ChatGPT；登录后浏览器会跳到一个打不开的 `localhost` 页面，这是正常的，把地址栏里的完整地址复制回管理页面。
3. 新授权的账号默认是禁用状态，核对无误后点击“启用”。这时 `/health/ready` 变为 200。

授权地址和回调地址等同于登录凭证，不要发给别人或截图公开。详见[管理面板](docs/guide/admin.md)。

### 7. 为设备创建 Key 并接入 Codex

在“访问密钥”页为每台设备或每个工具创建一个 Key，选择允许的模型。Key 只显示一次，请立即保存。

在客户端设备上把 Key 放进环境变量 `CODEXONE_API_KEY`，并在 Codex 配置（`~/.codex/config.toml`）中添加：

```toml
model = "<第 3 步配置的模型名>"
model_provider = "codexone"

[model_providers.codexone]
name = "openai"
base_url = "https://<数据域名>/backend-api/codex"
wire_api = "responses"
supports_websockets = true
env_key = "CODEXONE_API_KEY"
requires_openai_auth = false
http_headers = { "x-openai-actor-authorization" = "codexone" }
```

重启 Codex Desktop 或 CLI 并新建会话，发一条消息；管理页面的用量里能看到这次请求，就说明部署成功了。provider 名称和请求头只是客户端兼容设置，不代表官方授权。工具与图片权限见[客户端接入](docs/guide/client-setup.md)。

### 遇到问题

- **`docker pull` 很慢或卡住**：如果 dockerd 配置了代理，检查代理对 `ghcr.io` 和 `pkg-containers.githubusercontent.com` 是否可用，必要时把这两个域名加入 dockerd 的 `NO_PROXY`。
- **管理页面登录失败**：确认浏览器地址与 `--origin` 完全一致（协议、域名、端口），HTTPS 路线须通过 HTTPS；LAN 路线须使用安装器打印的 IP 和端口。
- **ready 一直是 503**：账号是否已授权**并且已启用**；管理页面首页的提醒会给出具体原因。
- **升级、备份与回退**：见[备份升级与回退](docs/guide/backup-upgrade.md)，升级前务必先阅读。

## 系统要求与已知限制

- 容器面向 **Linux amd64**，使用 host network 与本地命名卷，默认仅监听回环，由宿主 TLS 反代接入；可显式开启私有地址 LAN HTTP；不直接适用 Docker Desktop。模板设 768 MiB 内存上限，这不是最低宿主配置或吞吐承诺。
- 源码开发支持 Linux、macOS 与 Windows（WSL2），需要 Swift 6.4、Node.js 22.23.0 和 Python 3；也可直接用仓库的开发容器。见[贡献指南](CONTRIBUTING.md)。
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
