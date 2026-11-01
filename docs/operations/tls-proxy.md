# TLS 反代与 HTTPS 管理

为数据和管理入口配置 HTTPS 及正确的 SSE/WS 转发。

## 局域网 HTTP 风险

没有域名和证书时，可显式选择[局域网安装](../guide/linux-installation.md#局域网无域名)，用 `http://<私有 IP>:18081` 管理、`http://<私有 IP>:18080/backend-api/codex` 接入客户端，不需要反代。同一网络的设备可截获管理员秘密、session、Key 与请求内容；私有 IP、来源网段过滤和 HttpOnly 均不提供传输加密。仅在知情接受风险的可信私有网络使用。

不要在公共或不可信 Wi-Fi 使用；不要用路由器端口转发将明文入口暴露到公网。需要跨网络访问时改用 HTTPS 或 Tailscale 等私有网络。管理页面会常驻风险提示，启动日志也会警告。LAN 模式不内置 TLS、证书或 mDNS；IPv6 使用带方括号的 URL，例如 `http://[fd00::10]:18081`。

## 前提

使用与 Linux 安装同一宿主网络的 Nginx，将两个独立 HTTPS 域转发到网关数据/管理 loopback。HTTPS 模式下网关继续只监听回环；不要把明文端口公开到外网。安装入口见 [Linux 安装](../guide/linux-installation.md)，运行约束见 [O06/O10/O11](../reference/specs/operations.md)。

## 接入配置

从源码归档的 deploy 目录取 [TLS server 示例](../../deploy/nginx.conf.example)、[数据片段](../../deploy/nginx-data.conf)和[管理片段](../../deploy/nginx-admin.conf)。将片段安装到示例引用的 snippets 目录；TLS server/map 内容放入 Nginx 的 http 配置。替换域名、证书/私钥路径，按真实端口调整两个 proxy_pass，执行本机 `nginx -t` 后再按宿主管理方式加载。不要把示例直接覆盖用户现有 Nginx 配置。

私钥保持私有，仅 Nginx 主进程所需身份可读，不入源码/镜像。公开证书链与域名必须由客户端正常信任。管理 `.env` 的 `CODEXONE_ADMIN_PUBLIC_ORIGIN` 必须等于浏览器公开 origin（https、域名、非默认端口），修改后通过受控 Compose 重建 gateway。TLS 在外部终止不需要伪造 forwarded 头；模板保留 Host/Origin，清除 forwarded 类头。管理 session 仍由网关验证精确 Host/Origin/CSRF。

数据域只转发 `/v1/` 和 `/backend-api/codex/`，其他路径 404；管理域不提供生成入口。数据面需高熵 Key，管理员秘密与 Key 互不替代。按宿主安全策略限制管理域接入，域名分离不替代认证。

## 仅公开数据入口

[独立数据域示例](../../deploy/nginx-data-only.conf.example)复用数据片段，管理端口保持回环。使用独立域名、独立证书和 ACME webroot；首次签发前只加载示例中的 HTTP server，验证域名 DNS 与 challenge 可达后用 Certbot webroot 签发，再加载 TLS server。不要借助安装插件自动改写其他虚拟主机。

证书续期应保留 webroot challenge 路由，并配置仅在 `nginx -t` 成功后 reload 的 deploy hook；检查现有 Certbot timer。验证公网客户端正常信任证书、SSE/WSS 与拒绝路径，再撤掉临时客户端隧道。签发失败时保留原入口，清理本次新增配置；已有域名、证书与服务不做覆盖。

## 限制与失败语义

- 数据网关请求体上限 32 MiB，反代 client_max_body_size 为 33m，管理为 8 KiB；网关更细的模型/端点限制仍生效。反代超过 33m 时在生成准入前拒绝；网关对 JSON、multipart、WS 消息执行 32 MiB，并共享 48 MiB 正文预算（超过 8 MiB 先申请，耗尽返回 503 capacity_exhausted，HTTP Retry-After: 1），见[图片入口](../guide/images.md)。管理静态页面响应大小不受请求体上限影响。
- 数据 upstream 读/写空闲超时 1830 秒（高于网关最大执行期限 1800 秒），上传空闲超时 30 秒；管理分别 30/10 秒。它们是阶段之间的空闲间隔，不能当成整个执行的总期限；长 WS 空闲也可能触发关闭。
- SSE 不缓冲、不 gzip，WS 显式传递 Upgrade；流式请求体不落普通代理缓冲文件。关闭下游取消忽略和代理自动重试。504 或流中途断开不证明上游没有执行；没有可信终态时保留 unknown，不自动生成、退款或恢复旧余额。
- 原生 WSS 的 TLS/TCP 断开会经 Nginx 传至网关；上游并非必须在 3 秒内关闭。按 [P14a](../reference/specs/protocol.md#p14a原生-ws-客户端控制与前向兼容)，网关停止接收新请求，已 dispatch 的 turn 最多续读 10 秒且不超过原执行期限，有响应 ID 后仅补发一次定向中断。无 ID 时等待身份；有可信终态则保留用量并记客户端取消，否则关闭上游并保留 unknown 和预留暴露，不重放、不伪造额外费用。HTTP/SSE 断开仍直接取消。
- 反代禁用普通 URI access log，server error log 默认丢弃并只允许 critical；需要私有诊断时由操作者另外配置受保护、脱敏且有界的记录，不能启用可能泄露查询参数/签名 URL 的默认日志。TLS/反代失败需结合网关健康和无正文诊断判断。

## 隔离的本地验证

需要 Nginx（支持 `-e`）、OpenSSL CLI、编译后的网关和生产 SPA：

```sh
python3 scripts/verify_tls_proxy.py --binary .build/debug/codexone
# 已安装 web 锁文件依赖和本机 Chrome 时：
python3 scripts/verify_tls_proxy.py --binary .build/debug/codexone --browser
```

脚本使用临时端口、私有 CA/叶证书、合成上游和临时 SQLite；直接加载交付的 TLS 示例及两个片段，只替换端口/证书路径。验证默认配置后，为故障注入将私有副本的读/上传空闲超时缩至 1 秒，不更改交付默认值。进程退出回收全部证书、配置与临时状态；不访问个人认证，不改系统 Nginx 或证书信任。

WSS 断开验收区分两条路径：无响应 ID 的静默上游应在断开后约 10 秒关闭并记 unknown；已有 ID 的上游须在 3 秒内收到定向中断，此后才放行合成终态，验证用量仍结算为 cancelled。执行与 stub 期限均为 15 秒，晚于 12 秒断言上限，避免 stub 自行超时造成假通过；每次检查派发数和账本数，拒绝重放。可加 `--websocket-repetitions 5` 重复这两项。此处修正的是旧验收的 3 秒期望，与既有 10 秒续读契约一致；使用当前交付模板的实例无需为此修改 Nginx 配置或重启网关。

TLS socket 实际验证 CA 链和主机名，并拒绝不可信 CA/错误主机。浏览器直接连接真实 HTTPS/Nginx，不使用 relay/response fulfillment；仅新建的临时 Chrome 进程接受该次叶证书的 SPKI pin，不跳过全部证书错误、不导入系统根证书。这不能证明公共 CA 证书签发或实际用户域名配置正确。截图只含合成资料、凭证控件遮罩，位于忽略的 artifacts/tls-proxy-ui。

Linux amd64 release 的隔离复现（先完成候选构建）：

```sh
docker build --platform linux/amd64 --target verification -f deploy/Dockerfile -t codexone:tls-base .
# 按 Linux 安装文档构建 codexone:candidate，传入实际 SOURCE_REVISION。
docker build --platform linux/amd64 -f deploy/tls-verification.Dockerfile -t codexone:tls-verification .
docker run --rm --platform linux/amd64 --network none --read-only --user 10001:10001 \
  --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 128 --memory 768m \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m,mode=1777 --env PYTHONDONTWRITEBYTECODE=1 \
  --mount "type=bind,src=$PWD/scripts,dst=/test/scripts,readonly" \
  --mount "type=bind,src=$PWD/deploy,dst=/test/deploy,readonly" \
  codexone:tls-verification /test/scripts/verify_tls_proxy.py --binary /output/codexone
```

测试扩展镜像加入 Nginx/OpenSSL/Python 环境并取候选镜像的 SPA；产品 runtime 不增加这些工具。无外部网络的容器内仍执行真实 TLS socket。768 MiB/128 PID 只约束这次测试，不是参考弱服务器容量承诺。实际结果与未覆盖边界统一见 [STATUS](../../STATUS.md)。

## 相关文档

[文档导航](../README.md)
