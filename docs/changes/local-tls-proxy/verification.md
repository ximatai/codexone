# 本地 TLS 反代验证 · 2026-10-22

主 Agent 实现与执行；仅临时合成上游/身份/数据库和私有证书，不修改用户 Nginx/系统信任，不访问真实账号或消耗额度。

- macOS arm64 / debug 网关 / Nginx 1.31.7 / OpenSSL CLI 4.0.3：`python3 scripts/verify_tls_proxy.py --binary .build/debug/codexone` 通过。直接加载交付的 TLS server 示例和数据/管理 snippets，动态替换私有路径/loopback 端口；真实客户端校验 CA 与 SAN 主机名，不可信 CA/错误主机被拒绝。
- HTTP JSON 与逐事件 SSE、`/v1` 和 `/backend-api/codex`、gzip offer 下 SSE 无压缩；提供者终态被 gate 阻止时客户端已收到 created，证明没有等完整响应再送出。下游 TLS 断开使提供者连接关闭、账本 unknown，calls 恰好 +1，无生成重放。
- 实际 WSS 101/accept、两个前缀、同连接 previous_response_id 后续 turn 与 HTTP→WS 桥接通过；WSS 下游断开使对应提供者关闭并保留 unknown，无重放。不能由 socket 关闭推导真实提供者停止收费。
- 实际 HTTPS 管理认证/session、Secure/HttpOnly/Strict/Path=/ cookie、缺失/错误 CSRF、普通 Key 不能管理、错误 Host/Origin/端口及 forwarded 伪造拒绝；数据域不提供管理路由，管理域不提供数据生成入口。数据 8 MiB / 管理 8 KiB 的超限 Content-Length 在 dispatch 前拒绝，正常 16 KiB 合成输入通过。
- 私有配置故障注入：仅副本改成 1 秒读/上传空闲超时。半截上传约 1 秒有界关闭且无 attempt/上游调用；SSE 空闲与响应头前超时分别部分断流/504，提供者关闭、unknown、calls +1。交付默认数据 read/send 130 秒、body 30 秒未改。未把空闲超时称为总执行期限。
- `python3 scripts/verify_tls_proxy.py --binary .build/debug/codexone --browser` 通过。Chrome 全新临时上下文直接连接真实 HTTPS/Nginx，TLS securityDetails 为实际加密连接；没有 relay 或 response fulfillment。只对本次叶证书 SPKI 作进程级 pin，ignoreHTTPSErrors=false；独立 socket 负责完整链/主机名正反验证，未改系统根证书。实际登录、CSRF 403、创建/关闭一次性 Key、刷新保留、禁用后刷新仍禁用、登出/刷新失效通过；无持久浏览器秘密/CSP 错误。1440 大屏截图 `artifacts/tls-proxy-ui/desktop.png` 已查看，只有合成资料与遮罩凭证控件，未入库。
- Linux amd64 / Swift 6.4.1 release / Nginx 1.24.0 Ubuntu / OpenSSL CLI 3.0.13：测试专用 SDK 扩展镜像构建后，按候选 CI 的实际命令（公开 scripts/deploy 只读挂载，候选镜像内 SPA），在非 root/只读根/cap-drop ALL/无提权/无外部网络、768 MiB/128 PID 容器内执行完整 TLS socket harness 通过。二进制 SHA-256 `b323209f9302e4ae36a0de4732f1a016e359fb1e522fe1649cf8e929e42cd675`，与上一阶段 release socket/运行候选一致。容器已回收；这不是弱服务器容量证据。
- 主 Agent 自查：临时证书/秘密/状态独占私有目录；进程有 owner、超时和关闭等待。检查 gateway 与代理日志不含管理员秘密、Key/session/CSRF 格式、私有路径和合成查询标记。代理 access log 关闭，TLS server error log 默认丢弃；没有真实正文/图片或凭证进入仓库。

失败记录：初版新夹具误将 logout 成功写为 204、手写流请求漏 Content-Type，修正为已有契约后通过；新增半截上传断言仅接受 408，实测 Nginx 流式上传可直接断连，改为验证有界关闭且无 dispatch；Linux 只读测试暴露默认临时目录不可写，显式设置所有测试临时路径后通过。未放宽产品限制。后两项修复后仅重跑 TLS 定向测试，未重复未改变的 Swift/前端/原有协议全集。

集中 review：UI reviewer 未发现明确问题；后端 reviewer 发现 P2 部分失败清理缺陷。主 Agent 改用立即注册的独立 owner 清理，保证 Nginx 关闭断言不能跳过网关/provider，早期文件写失败也关闭已获取 socket；Nginx 独立进程组，master 异常时回收 worker。macOS `--cleanup-failure-only` 注入私有文件写失败与 master SIGKILL，确认所有 owner/监听器回收；另定向验证 Host/Origin 丢失非默认端口拒绝。Linux release 完整 TLS harness（含新失败注入）通过，未重复浏览器/Swift/前端全集。

候选 CI 已接入同一 Linux TLS 命令，尚未远程运行。测试扩展中的 Nginx/Python/OpenSSL CLI 不进入产品 runtime。Desktop、真实订阅、M5 已有输出恢复、用户真实域名/公共 CA/公网接入、弱服务器容量、维护/恢复与旧服务替代仍不在本次通过范围。
