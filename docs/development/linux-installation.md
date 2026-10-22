# Linux amd64 候选安装

使用 Linux Docker Engine 与 Compose v2、Python 3、本地可靠磁盘。Compose 使用 host network，使服务仍只监听宿主 `127.0.0.1:18080/18081`；不要把此模式直接迁移到 macOS/Windows Docker Desktop。data 使用 Engine 本地磁盘上的命名 volume，不使用宿主共享 bind 或网络盘。外部 HTTPS 由宿主反代提供，管理域名必须与配置的 origin 完全一致。其他平台需单独验收。

## 构建与来源

在干净源码提交上构建，不把账号、安装目录或构建缓存放进上下文：

```sh
docker build --platform linux/amd64 --target verification -f deploy/Dockerfile .
docker build --platform linux/amd64 --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" \
  --build-arg VERSION=0.0.0-dev -f deploy/Dockerfile -t codexone:candidate .
python3 scripts/verify_installation.py --image codexone:candidate
# 本机有 Chrome 且已安装 web 锁文件依赖时，可增加 --browser 验收打包界面。
# python3 scripts/verify_installation.py --image codexone:candidate --browser
docker image inspect codexone:candidate --format '{{.Id}}'
```

`--browser` 使用临时 Chrome 上下文实际操作镜像中的 SPA 和管理 API，经隔离 curl relay 转发 HTTPS 路由以检查浏览器 cookie；它不证明宿主 TLS/Nginx 配置。截图仅含合成资料，凭证控件遮罩，保存在忽略的 artifacts 目录。

镜像标签和 `/opt/release.json` 保存源码 revision/version；安装时使用镜像 ID 或 registry digest，不能用可变 tag。`.dockerignore` 只允许产品源码、锁文件、测试 target、合成验证脚本和构建文件进入上下文。多阶段构建分别使用锁定 Node/Swift 工具链；verification target 在无网络环境检查优化后二进制的 HTTP/SSE/WS/Images 与失败路径，之后组装运行层。运行层没有编译器、Node、Python 或源码测试。

项目 LICENSE 位于 `/opt/codexone/LICENSE`；Swift checkouts 与 npm 生产依赖自带的 LICENSE/NOTICE/COPYING 文件按包路径分别收集到 `/opt/codexone/licenses/swift`、`/opt/codexone/licenses/npm`，与最终产物一同交付。

CI 的 Linux candidate 工作流在阶段出口手动触发，构建、合成安装测试并上传带源码归档/标识、镜像 ID 和 SHA256SUMS 的候选包。它不登录 registry 或推送/发布。下载包后先核对校验和，再 `docker load --input codexone-linux-amd64.tar.gz`；校验和验证完整性，不能单独证明来源，仍需核对受信工作流和源码 revision。安装工具和文档随源码归档提供。

## 新安装

以下占位值须替换。安装目录放在源码 checkout 外，且必须不存在；初始化拒绝覆盖现有目录或链接。默认运行 UID/GID 为执行初始化的非 root 用户；root 初始化时必须显式给出非 root `--uid` 和 `--gid`。运行用户须能访问本地数据盘。

```sh
python3 deploy/init-install.py ../codexone-private \
  --image sha256:REPLACE_WITH_LOCAL_IMAGE_ID \
  --origin https://admin.example.invalid
cd ../codexone-private
docker compose run --rm gateway --check-config
docker compose up -d
docker compose ps
```

初始化生成 0700 安装/secrets 目录和 0600 文件，并生成唯一 Compose project 与 data volume 名称；此时尚不创建卷。首次 Compose 会创建卷并执行隔离的 init-data：无网络、只挂数据、只为新空卷设定运行 UID/GID 与 0700 权限，非空卷归属不符明确拒绝；不递归改写既有文件。管理员秘密、账号主密钥只写入独立文件，不打印值、不进入 `.env`。先私下编辑 `secrets/pool.json` 的模型/profile、价格和边界，再以实际二进制 `--check-config` 校验。示例模型是占位符；没有账号时仍能管理，readiness 为 503。账户授权操作参见[账号凭证](account-credentials.md)，不要把私人配置提交到仓库。

首次浏览器登录从私有 `secrets/admin` 文件取得秘密，经精确 HTTPS 管理 origin 登录。管理 session 的 Secure cookie 要求 HTTPS；不要把明文 HTTP 直接暴露外网。数据面 Key 与管理员秘密互不替代。

gateway 以显式非 root UID 运行、只读根、丢弃 capabilities、禁止提权；data 本地卷可写、secrets 文件只读、`/tmp` 为有界 tmpfs。短命 init-data 仅以 root 和 CHOWN/FOWNER/DAC_OVERRIDE 设置空卷目录归属，根只读且无网络、不挂 secrets，完成后 gateway 才启动。768 MiB / 128 PID 是安装候选的限制，不是弱服务器容量承诺。live 只检查进程存活；ready 为 503 不触发自动重启。host network 的端口冲突须先处理，不能用映射端口改变回环隔离。

## TLS 反代

[Nginx 模板](../../deploy/nginx.conf.example) 分开数据与管理 TLS server；证书、域名、可信接入和防火墙由宿主管理。map 放在 http 级别，管理 Host 保留公开 origin 的端口。数据路径关闭 SSE 缓冲、保留 WS Upgrade、设置有限大小与超时；反代限制须与模型/profile 相容。上线前必须通过真实反代的 SSE/WS/取消/大小/超时检查，模板不是这些行为的验收证据。服务不依赖未认证的 forwarded 头来授权。

## 停止、升级与回退边界

```sh
docker compose stop
# 私下修改 .env 中的不可变镜像引用；保持 data 与独立主密钥。
docker compose run --rm gateway --check-config
docker compose run --rm gateway --migrate
docker compose up -d
```

data 卷名保存在私有 `.env` 的 CODEXONE_DATA_VOLUME；普通 `docker compose down` 保留卷。升级不得使用 `down -v` 或删除卷，数据和迁移备份均在卷内；不能用新的空卷冒充已有数据升级。迁移与在线服务共用实例锁；须先停服。普通启动拒绝不兼容旧 schema；显式迁移先产生私有一致性备份，再升级。保留迁移输出所指版本对应的主密钥和备份。新增安装目录不能替代已有安装；不要重新生成主密钥覆盖现有密文依赖。

同 schema 的兼容二进制回退与恢复旧库是两回事。恢复旧快照可能丢失新区间的已执行项，不得直接复制旧库后重启接单；O03/O04 要求维护态、披露缺失区间和审计额度基线。现有迁移命令不能替代完整 restore/reconcile 流程。迁移失败保持停止，检查私有资料并保留源库；不要自动重试覆盖或通过删除 data 绕过问题。旧服务替代、弱服务器混合容量和真实客户端兼容按 [验收定义](verification.md) 独立执行，具体交付状态只查 [STATUS](../../STATUS.md)。
