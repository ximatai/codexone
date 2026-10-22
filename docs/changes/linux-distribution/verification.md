# 本机候选与安装验证 · 2026-10-22

主 Agent 实现、自查、执行实际镜像和浏览器验收；本记录不代表正式发布、真实账号/旧服务迁移或弱服务器容量。

- macOS arm64：`python3 scripts/verify_installation.py --binary .build/debug/codexone` 通过。独占私有初始化、0700/0600、拒绝覆盖/链接、非法 origin/镜像引用/UID/GID/超限或畸形配置、真实二进制配置成功/权限过宽拒绝，不创建核心库。Linux amd64 Python 3.12 另验证 root 默认拒绝、显式非 root 归属、唯一 project/volume 与不覆盖；只挂公共 deploy 输入、无网络、临时文件系统。
- Linux amd64 / Swift 6.4.1：`docker build --platform linux/amd64 --target verification -f deploy/Dockerfile .` 通过。单并发 native release 完整构建，HTTP JSON/SSE、取消/unknown、持久归属失败、原生/桥接 WS lane/终态/关闭以及 Images JSON/SSE/multipart/主动编辑/权限/用量/失败/不重放均通过实际 socket。验证 RUN 无网络，仅合成上游。固定工具链仍有 native build system 弃用警告，后续升级需独立复核。
- `docker build --platform linux/amd64 --build-arg SOURCE_REVISION=<commit> -f deploy/Dockerfile -t codexone:m6-candidate .` 实际镜像通过；Swift/Node/运行基底锁定版本及 digest。被测试运行镜像源码标识 `e33223e`；之后的追加修复只改安装配置/脚本，不改变镜像内二进制或 SPA。二进制 SHA-256 `b323209f9302e4ae36a0de4732f1a016e359fb1e522fe1649cf8e929e42cd675` 与 socket 验证产物逐字节一致。
- `python3 scripts/verify_installation.py --image codexone:m6-candidate --browser` 通过。执行交付的 Compose 配置（review 后补受控入口，见下）：拒绝 root 目标、新空卷初始化、非空卷归属保护、配置权限拒绝、live 200/无账号 ready 503、实际健康命令、SPA/JS、session/CSRF 与普通 Key 隔离、Key 创建/重启保留；实际 gateway 非 root、只读根/秘密、可写 data/tmp、CapEff/CapBnd=0、NoNewPrivs=1、768 MiB/128 PID。在线迁移被实例锁拒绝；停止 exit 0/无 OOM，合成 v5 语义库普通启动 exit 1 且无 LISTENING，显式一致性备份/迁移与重复幂等，v5 备份/当前 v6 完整性及 Key 保留、旧图片权限默认拒绝。
- Chrome 大屏 1440：加载镜像内 SPA，经 curl relay 到实际容器 API，完成登录、Secure/HttpOnly/Strict cookie、创建/清除一次性凭证、刷新保留与登出；无持久浏览器秘密、无运行时/CSP 错误。截图 `artifacts/installation-ui/desktop.png` 已查看，只有合成资料、凭证控件遮罩，不入库。HTTPS route fulfillment 不证明真实 TLS/Nginx。
- 自查后 `python3 scripts/verify_installation.py --image codexone:m6-candidate` 定向回归通过：额外注入 init-data 的目录读取失败，非零退出且不改非空卷归属；补齐父目录同步、nocopy 与私有卷结束清理。未再运行未改变的浏览器/协议全集。
- 集中 review 发现真实交付命令仍受宿主 Compose 环境覆盖，测试 helper 清理变量导致假通过。主 Agent 交付 `compose-install.py`，固定私有文件/env/project、清理环境覆盖，并让全部安装流程使用该入口。污染 FILE/project/image/volume/UID/origin 的环境直接进入 launcher，配置仍绑定本安装；切换安装的命令行参数被拒绝。macOS 实际配置与 `python3 scripts/verify_installation.py --image codexone:m6-candidate` 实际 Linux 安装/迁移定向回归通过。首次参数保护误拒容器内 `find -print`，按 Compose run/exec 的 service 边界修正后通过；未重跑未改变的浏览器/协议。
- 集中 review 原环境覆盖问题已由两位 reviewer 定向确认关闭；后端 reviewer 额外发现 `logs -f` 被参数保护误拒，主 Agent 修复并以实际入口日志 follow、污染环境/配置隔离及 host binary 定向回归通过，reviewer 复审确认关闭。Linux root initializer 另确认新 launcher 随私有文件以目标 UID/0600 交付。
- 候选 CI YAML 语法通过；工作流仅阶段出口手动触发，源码构建、合成验证、归档/校验和及上传候选，无 registry 登录/推送。尚未远程运行。文档/依赖方向检查通过；Swift Sources/Tests 与前端产品代码未变，沿用 M4 已通过的 152 项 Swift、35 项前端及浏览器证据，不重复全量。

失败及取舍：首次公共依赖下载遇 TLS/长等待，复用同锁文件、已检查无凭证配置的 29 个公共仓库缓存；共享 2 CPU/约 2.8 GiB Docker VM 并发构建响应迟滞，中止后改串行，均不算通过。实际镜像检查抓到 npm 传递依赖许可证缺失，补 `--all` 后通过。macOS 共享 bind 最小 flock 探针在同/跨容器均错误取得第二把锁，Linux 本地 volume 均正确拒绝，因此 data 改为本地卷；空卷 copy-up 的属主重置由 nocopy 解决。保留这些失败，不把共享目录验收等同 Linux 本地磁盘。

边界：本机 Linux 容器/虚拟盘与合成资料，不是 O14 参考宿主、掉电或长压证据。真实 TLS 反代 SSE/WS、低磁盘/WAL/备份空间、旧快照维护态与基线核对、旧服务替代切换/回退尚须独立验收；M5 读取契约、Codex Desktop 与真实订阅仍保留缺口。没有真实调用/额度消耗、推送、远程 CI、发布或用户服务器部署。
