# Linux amd64 安装部署

在 Linux amd64 上使用 Docker Compose 安装和维护网关。

使用 Linux Docker Engine 与 Compose v2、Python 3、本地可靠磁盘。Compose 使用 host network，使服务默认只监听宿主 `127.0.0.1:18080/18081`，可显式增加私有 LAN 地址；不要把此模式直接迁移到 macOS/Windows Docker Desktop。data 与 backups 使用 Engine 本地磁盘上的命名 volume，不使用宿主共享 bind 或网络盘。外部 HTTPS 由宿主反代提供，管理域名必须与配置的 origin 完全一致。其他平台需单独验收。


## 前提

使用 Linux amd64 Docker Engine、Compose v2、Python 3 和可靠本地磁盘，按路线准备：可信局域网可用固定私有 IP；公网或域名路线准备精确 HTTPS 管理 origin 和 TLS 证书。

## 获取镜像

从 GHCR 拉取精确版本并解析本机不可变 ID，也可以按下节从源码构建 candidate：

```sh
docker pull ghcr.io/ximatai/codexone:0.26.4
docker image inspect ghcr.io/ximatai/codexone:0.26.4 --format '{{.Id}}'
```

下文初始化的 `--image` 必须使用实际输出的完整 `sha256:` ID 或受信 digest。该 ID 只在本机有意义：containerd 镜像存储下等于拉取的 registry digest，传统存储下等于镜像配置 digest（Release 的 `image-id.txt`）；跨机器核对以 registry digest 和来源证明为准。正式版镜像提供精确版本与 latest；预发布只提供精确版本，不更新 latest，也不提供年份浮动标签。

## 从源码构建

在干净源码提交上构建，不把账号、安装目录或构建缓存放进上下文：

```sh
docker build --platform linux/amd64 --target verification -f deploy/Dockerfile .
docker build --platform linux/amd64 --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --build-arg VERSION=0.26.4 -f deploy/Dockerfile -t codexone:candidate .
python3 scripts/verify_installation.py --image codexone:candidate
# 本机有 Chrome 且已安装 web 锁文件依赖时，可增加 --browser 验收打包界面。
# python3 scripts/verify_installation.py --image codexone:candidate --browser
docker image inspect codexone:candidate --format '{{.Id}}'
```

`--browser` 使用临时 Chrome 上下文实际操作镜像中的 SPA 和管理 API，经隔离 curl relay 转发 HTTPS 路由以检查浏览器 cookie；它不证明宿主 TLS/Nginx 配置。截图仅含合成资料，凭证控件遮罩，保存在忽略的 artifacts 目录。

GitHub 访问受限时，可预先按 `Package.resolved` 的 revision 把依赖取成 `OWNER/REPO.git` 布局的本地裸仓库目录，构建时追加 `--build-context swiftpm-mirrors=<该目录>`；仅这两次 Swift 构建把 GitHub 地址改写到只读挂载的镜像，不写入镜像层，锁定版本不变。默认上下文为空，行为与直接联网相同。npm 官方源受限时同理可加 `--build-arg NPM_REGISTRY=<镜像源>`，lockfile 完整性哈希仍逐包校验。Ubuntu 源受限时可加 `--build-arg APT_MIRROR=<镜像源 /ubuntu 地址>`，仅在安装期间替换，结束后恢复原源配置。

镜像标签和 `/opt/release.json` 保存源码 revision/version，release manifest 另声明 schemaVersion=11；安装时使用镜像 ID 或 registry digest，不能用可变 tag。`.dockerignore` 只允许产品源码、锁文件、测试 target、合成验证脚本和构建文件进入上下文。多阶段构建分别使用锁定 Node/Swift 工具链；Swift release 保留 `-O` 和单并发、默认每批1文件（SWIFT_BATCH_LIMIT），仅大型 Adapters target 关闭 whole-module optimization 以减少单次编译峰值（不代表运行容量）；verification target 在无网络环境检查优化后二进制的 HTTP/SSE/WS/Images、快照/主密钥/存储观测及合成迁移切回失败路径，之后组装运行层。运行候选在优化构建后剥离DWARF调试段，保留可执行代码和普通符号表，验证/归档以剥离后的同一程序为准。运行层没有编译器、Node、Python 或源码测试。

项目 LICENSE 位于 `/opt/codexone/LICENSE`；Swift checkouts 与 npm 生产依赖自带的 LICENSE/NOTICE/COPYING 文件按包路径分别收集到 `/opt/codexone/licenses/swift`、`/opt/codexone/licenses/npm`，与最终产物一同交付。

Release 工作流的手动 dry-run 接受 ref，构建并执行 Linux 合成 socket、TLS 反代与真实安装验证，上传源码、二进制、许可、镜像 ID、校验和与独立镜像归档，不登录 registry 或推送/发布。将两个验证产物分别解压到 `verified-release-files/` 与 `verified-linux-amd64-image/` 后，在前者执行 `sha256sum --check SHA256SUMS`，再在后者用 `sha256sum --check ../verified-release-files/image-archive-sha256.txt` 核对归档，然后 `docker load --input codexone-linux-amd64.tar.gz`。正式 tag 流程验证后才推送同一镜像、生成来源证明并创建 Release；附件清单和 `gh attestation verify` 命令见[发版规则](../development/releasing.md)。校验和验证完整性，不能单独证明来源，仍需核对受信工作流和源码 revision。安装工具和文档随源码归档提供。

## 局域网（无域名）

先阅读[明文风险](../operations/tls-proxy.md#局域网-http-风险)。局域网模式从 v0.26.2 起提供。准备不可变镜像 ID 后，四步路线见 [README](../../README.md#局域网部署无域名)：初始化、配置模型、启动、打开管理页面。

```sh
python3 deploy/init-install.py ../codexone-private \
  --image sha256:REPLACE_WITH_LOCAL_IMAGE_ID --lan 192.168.1.10
# 可选收窄来源：追加 --lan-allow 192.168.1.0/24
cd ../codexone-private
# 编辑 secrets/pool.json 的模型名后：
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py up -d
```

`--lan` 与 `--origin` 互斥，`--lan-allow` 只可与 `--lan` 一起使用。安装器自动写入私有 `.env`：`CODEXONE_LISTEN_ADDRESS=192.168.1.10`、`CODEXONE_ALLOWED_NETWORKS=`（空为默认私有网段加回环）、`CODEXONE_ADMIN_PUBLIC_ORIGIN=http://192.168.1.10:18081`，并打印风险、管理 URL 与客户端 base_url。IP 必须配置在本机网卡上；网关同时保留 `127.0.0.1`，健康检查无需改动。允许的地址为 10/8、172.16/12、192.168/16、100.64/10、fc00::/7；不接受公网、通配、主机名或 IPv6 zone ID。可选来源 CIDR 只能收窄这些私有网段或回环；至多 64 项，以逗号连接，不含空白。访问地址必须精确匹配管理 origin，不能用另一个别名登录。

## 切换局域网与 HTTPS

沿用原安装目录、卷、主密钥和管理员秘密。先执行 `python3 compose-install.py stop`；只编辑私有 `.env`，不要重新初始化：

- 转到 LAN：设置 `CODEXONE_LISTEN_ADDRESS=192.168.1.10`、`CODEXONE_ALLOWED_NETWORKS=`（或收窄 CIDR）、`CODEXONE_ADMIN_PUBLIC_ORIGIN=http://192.168.1.10:18081`。先确认明文风险与本机 IP；HTTP 非回环 origin 的主机必须等于监听地址。
- 回到 HTTPS：删除或清空 `CODEXONE_LISTEN_ADDRESS` 与 `CODEXONE_ALLOWED_NETWORKS`，设置 `CODEXONE_ADMIN_PUBLIC_ORIGIN=https://admin.example.invalid`，配置下文的 TLS 反代。客户端 base_url 同步改回 HTTPS。

随后执行 `python3 compose-install.py run --rm gateway --check-config`、`python3 compose-install.py up -d`，用新地址重新登录并检查健康/客户端连接。重启使内存 session 失效；无 schema 变更。回退到不支持 LAN 的旧版本前必须先恢复 HTTPS `.env`，确认旧程序与当前 schema 兼容，避免旧程序忽略新变量后无法访问。

## 新安装（HTTPS）

以下占位值须替换。安装目录放在源码 checkout 外，且必须不存在；初始化拒绝覆盖现有目录或链接。默认运行 UID/GID 为执行初始化的非 root 用户；root 初始化时必须显式给出非 root `--uid` 和 `--gid`。运行用户须能访问本地数据盘。

```sh
python3 deploy/init-install.py ../codexone-private \
  --image sha256:REPLACE_WITH_LOCAL_IMAGE_ID \
  --origin https://admin.example.invalid
cd ../codexone-private
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py up -d
python3 compose-install.py ps
```

安装后的 Compose 操作统一使用 `python3 compose-install.py <command>`：入口固定私有 compose/env 文件、安装目录与唯一 project，剥离宿主 `COMPOSE_` / `CODEXONE_` 覆盖并拒绝命令行切换安装。不要用裸 Compose 命令绕过入口。Docker Engine/context 仍由操作者选择，须指向预期的本地 Linux Engine。

初始化生成 0700 安装/secrets 目录和 0600 文件，并生成唯一 Compose project、data 与 backups volume 名称；此时尚不创建卷。首次 Compose 会创建卷并执行隔离的 init-data：无网络、只挂数据与备份卷、只为新空卷设定运行 UID/GID 与 0700 权限，非空卷归属不符明确拒绝；不递归改写既有文件。管理员秘密、账号主密钥只写入独立文件，不打印值、不进入 `.env`。先私下编辑 `secrets/pool.json` 的模型/profile、价格和边界，再以实际二进制 `--check-config` 校验。示例模型是占位符；没有账号时仍能管理，readiness 为 503。账户授权操作参见[账号凭证](../reference/account-credentials.md)，不要把私人配置提交到仓库。

HTTPS 路线首次浏览器登录从私有 `secrets/admin` 文件取得秘密，经精确 HTTPS 管理 origin 登录。该路线管理 session 的 Secure cookie 要求 HTTPS；不要把明文 HTTP 直接暴露外网。数据面 Key 与管理员秘密互不替代。

gateway 以显式非 root UID 运行、只读根、丢弃 capabilities、禁止提权；data 与 backups 本地卷可写、secrets 文件只读、`/tmp` 为有界 tmpfs。短命 init-data 仅以 root 和 CHOWN/FOWNER/DAC_OVERRIDE 设置空卷目录归属，根只读且无网络、不挂 secrets，完成后 gateway 才启动。768 MiB / 128 PID 是安装候选的限制，不是弱服务器容量承诺。live 只检查进程存活；ready 为 503 不触发自动重启。host network 的端口冲突须先处理，不能用映射端口改变回环隔离。

## 自动重启与维护停机

gateway 使用 `restart: unless-stopped`：进程意外退出后由 Docker 自动拉起；宿主机重启后，随 Docker Engine 启动恢复原先运行的 gateway（须启用 Engine 开机启动）。init-data 保持不重启。每次启动仍校验配置、schema、密钥和实例锁并完成恢复，不自动迁移，也不重放可能已执行的请求。ready 503 或 unhealthy 本身不触发重启。

需要保持停机时，在安装目录执行 `python3 compose-install.py stop`；`down` 则同时删除容器，保留命名数据卷。两者都不会因 Engine 或宿主机重启自动拉起，恢复服务须显式执行 `python3 compose-install.py up -d`。升级现有安装须更新 compose.yaml 与 compose-install.py 后执行 `up -d`，仅 `restart` 不会应用模板变更。

执行 `--migrate`、离线 `--backup`、`--restore` 或密钥维护前，必须先 `stop` gateway，维护成功后再 `up -d`。安装入口为所有 `run` 强制启用 `--rm` 并拒绝关闭；这是 [Compose 文档](https://docs.docker.com/reference/cli/docker/compose/run/)明确保证覆盖服务重启策略的方式，失败的一次性命令也会退出并移除，不自动重试。

配置错误以 78 退出且不开 listener；连续失败由 Docker 递增退避，普通日志仍受 10 MiB × 5 轮转限制。自动重启不能修复配置或代替故障排查。trial watch 仍对 RestartCount 增量报 `container_restarted`，自动恢复也须检查原因。

## 定时备份与日志轮转

Compose 的独立 backups 命名卷挂载 `/var/backups/codexone` 并设置 `CODEXONE_BACKUP_DIRECTORY`；init-data 同时检查两卷归属与 0700 权限。launcher 校验两卷均属于唯一安装标识，剥离宿主同名环境覆盖。旧安装升级模板后若 `.env` 未含备份卷字段，launcher 从原 project 派生同一隔离卷名；显式字段不一致则拒绝。

服务启动后 10 分钟首次备份，每轮结束等待 24 小时；normal 才运行，保留 7 份自检成功的 bundle。认证存储接口与首页展示最近成功时间和提醒，格式、权限与恢复见[快照维护](../operations/snapshot-maintenance.md)。必须定期将备份和依赖的主密钥分别异地保存并演练恢复；同机独立卷不防磁盘/主机丢失。升级保留两个卷及 secrets，不运行 down -v。

所有服务（含 init-data）日志使用 json-file，每文件 10m、最多 5 文件；已有容器须用新模板重新创建才生效，不涉及 SQLite 账本/审计。源码侧可执行 `python3 scripts/check_backup_compose.py`（需 PyYAML）解析模板并校验安装标识；Linux 卷归属、真实镜像备份/恢复和日志配置仍须独立验收。

## TLS 反代

[Nginx TLS server 示例](../../deploy/nginx.conf.example) 与[数据片段](../../deploy/nginx-data.conf)、[管理片段](../../deploy/nginx-admin.conf) 配套使用；证书、域名、可信接入和防火墙由宿主管理。安装、限制解释和隔离的真实 TLS 验证命令见 [TLS 反代](../operations/tls-proxy.md)。map 放在 http 级别，管理 Host 保留公开 origin 的端口。数据路径关闭 SSE 缓冲、保留 WS Upgrade、禁止生成自动重试；上线前仍须按实际域名/证书/模型配置验收，不能仅复制模板便宣布用户部署通过。服务不依赖 forwarded 头来授权。

## 停止、升级与回退边界

```sh
python3 compose-install.py stop
# 私下修改 .env 中的不可变镜像引用；保持 data 与独立主密钥。
python3 compose-install.py run --rm gateway --check-config
python3 compose-install.py run --rm gateway --migrate
python3 compose-install.py up -d
```

data/备份卷名保存在私有 `.env` 的 CODEXONE_DATA_VOLUME/CODEXONE_BACKUP_VOLUME；普通 `python3 compose-install.py down` 保留卷。升级不得使用 `down -v` 或删除卷，数据和迁移备份均在卷内；不能用新的空卷冒充已有数据升级。迁移与在线服务共用实例锁；须先停服。普通启动拒绝不兼容旧 schema；显式迁移先产生私有一致性备份，再升级。保留迁移输出所指版本对应的主密钥和备份。新增安装目录不能替代已有安装；不要重新生成主密钥覆盖现有密文依赖。

同 schema 的兼容二进制回退与恢复旧库是两回事。恢复旧快照可能丢失新区间的已执行项，不得直接复制旧库后重启接单；O03/O04 要求维护态、披露缺失区间和审计额度基线。显式旧快照恢复与审计核对使用[核心快照维护](../operations/snapshot-maintenance.md)，不能用迁移前单文件备份替代完成 bundle。迁移失败保持停止，检查私有资料并保留源库；不要自动重试覆盖或通过删除 data 绕过问题。旧服务替代、弱服务器混合容量和真实客户端兼容按 [验收定义](../development/verification.md) 独立执行，具体交付状态只查 [STATUS](../../STATUS.md)。

## 可选旧产物的回退演练

```sh
python3 scripts/verify_installation.py --image codexone:candidate \
  --incompatible-image codexone:rollback-peer --incompatible-schema 8 --browser
```

当前schema v11不能用v10及更旧版本作同库兼容回退。上述命令仅在另行准备受信的实际v8镜像后运行，通用Release CI不再构建固定v8历史peer；删除理由和保留的通用检查见[发版规则](../development/releasing.md)。安装脚本的incompatible-schema缺省6，也可选7/8/9/10。镜像须实际存在，脚本解析不可变ID。未来有受信、验证过当前schema/信封/配置兼容的旧v11候选后，才可用previous-image验证同库回退；必须是不同实际二进制，不能同一二进制换tag，也不能改数据库版本号。旧版本不支持 v11，不能通过改数据库版本号绕过校验。

回退到不支持 null 限额的旧二进制前，先通过管理入口把所有不限 Key 改为五项显式数值；schema 相同也不代表旧版本可解码 null，否则旧版本可能拒绝启动或拒绝这些 Key。此调整不清除历史账本或 unknown 责任。

实际运维回退先暂停入口/收敛并停服，保存新库一致性 bundle 与全部解密依赖；在私有 `.env` 仅替换已验兼容的不可变镜像引用，保留原卷和原 secrets，运行 `--check-config` 后启动并检查。schema 不兼容时停止，不运行旧版本 migration 或删除新库。恢复旧快照须走维护态流程；合成旧服务转换与新增用量核对见[迁移切回](migration-cutback.md)。

发行候选归档应保留精确源码 revision/归档、镜像 ID、实际二进制 SHA-256 和整体 SHA256SUMS；若执行了旧peer演练，还须交付该peer的镜像、旧产品 revision、实际构建源码归档（含编译配置补丁）和二进制摘要，避免只有回退说明却没有可用旧产物。校验标签与真实产物，不因流水线模板存在便声明远端运行成功。

### 可选HTTP出网代理

在安装目录的私有.env添加CODEXONE_UPSTREAM_HTTP_PROXY=http://proxy.example.invalid:7890，再使用受控compose-install.py入口启动/升级。空值保持直连，launcher不会采用宿主同名环境覆盖私有manifest；代理配置适用于HTTP/WS/认证/额度，失败不直连回退，目标TLS保持验证。真实代理地址与凭证不放进公开仓库。

Linux 镜像、迁移和回退需在对应环境实际验证；工作流存在不代表已成功运行。

## 相关文档

[文档导航](../README.md)
