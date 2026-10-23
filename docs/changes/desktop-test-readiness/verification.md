# Desktop 测试准备验证 · 2026-10-23

## 账号闭环

主Agent亲自拆出页面控制hook，列表展示策略/授权/额度摘要，授权和账号详情采用Mantine抽屉。详情与授权抽屉内保留重新读取和失败提示；scope锁仍归共享session，关闭/导航不能绕过未知结果。无当前观测不伪称正常或余额为零，常态摘要不重复健康说明；窗口口径按需展开。账号凭证/API/存储语义不变。

macOS前端完整43项测试、lint/格式/类型检查通过；最终布局细化后17项账号回归和生产构建通过。新增回归覆盖授权后读取失败仍能在抽屉内核对、关闭详情取消请求；原6项会话/迟到响应/未知写入和4项观测失败/缺失比例测试保持。实际Chrome合成OAuth流程覆盖PKCE/默认禁用/启用、CAS、提交后丢响应与失败重读锁、刷新拒绝/重新授权、额度成功/失败保留/陈旧/受限及会话替换/登出；首轮会话更新提示断言失败，后续改为直接定位提示文本；失败尝试不计通过，不修改业务重试。

主Agent另用真实浏览器完成合成授权、启用和额度读取，并观察大屏抽屉；不访问真实callback监听或订阅。提交 `ef0f8d3` 后两位subagent集中只读review未发现新增P1/P2；Linux amd64 Node22静态生产构建通过。最终Chrome全账号流程通过，CSP与local/session storage检查保持；review提示一次性授权关闭动画中的截图不能作最终布局证据，截图检查增加抽屉真正卸载屏障。未更改Swift业务，不重复已通过后端全集。

## 长连接与图片边界

实测合法四图合计6MiB multipart被转换后的8MiB请求门限二次拒绝（413/request_too_large）。主Agent将外部上传限额与内部9MiB封套预算分开，专用构造入口仍复用全部引用/图片校验；只在内部图片上游发送不转义斜杠，普通和下游WS限制不变。定向Swift图片13项通过，完整后端与两平台长样本见下方出口结果。

排错记录：最初30秒夹具执行配置在debug最大图片输出时触发执行期限，改用产品已有120秒上限，不提高产品最大期限；原字节串比对忽略JSON斜杠转义，改为解析SSE终态后精确核对图片；native大帧沿用小帧dial的短socket超时，改为覆盖120秒执行上限的130秒测试读取期限。上述失败不计全量通过，早期3秒样本不称长寿命验收。最大容器包含合法附属填充块，不代证真实提供者/所有像素格式。

`94f6ae5` 集中review：预算入口未发现P1/P2；测试review发现重复请求断言留在handler线程、以及socket.timeout可被误计取消成功两项P2。主Agent改为共享有界错误/重放计数，由主owner等全部handler退出后断言；只接受EOF/reset/close帧，Python3.9的socket.timeout单独识别。新增真实HTTP重复调用、保持开放的WS超时反向检查及真实关闭正例，守卫验证通过。取消SSE读取改用HTTPResponse解chunk后核对created。修复前长样本未作为出口通过。macOS完整175项Swift及全部后端脚本已通过，生产代码未再改变，不重复全集。

原生WS夹具预热未报告usage，持久结果应额外保留1个warmup unknown/1单位预留。原总数断言仅计2个取消unknown而失败（实际8 settled/3 unknown）；现按principal/mode分别核对预热和取消，其他生成必须settled，不修改提供者usage或产品额度语义。

最终出口：`bd38964` 的同一夹具SHA-256 `a692273991eff40b5d673f2db5d35392f36b193e4b430e75aeaf0187dee20949`，macOS arm64 debug/Swift6.4/Python3.9.6 与 Linux amd64 release/Swift6.4.1/Python3.12.3 均完成 `verify_desktop_boundaries.py --duration 125`（both）。HTTP同一TCP 33轮/125秒；WS配置另保持同一原生上游连接32轮/125秒，预热与previous_response_id连续。两配置分别37 settled/1取消unknown、68 settled/2取消unknown+1预热unknown；主owner核对全部handler退出、失败/重放均0、尝试与提供者调用一致、预留按主体/模式独立核对。四图合计6MiB（含大量斜杠base64）、图+mask合计6MiB、4MiB输入输出工具均通过；数量/单图/合计越界及外部8MiB+1拒绝通过。测试守卫修复及最后预热账核对均复审关闭，无新增P1/P2。

两平台HTTP/WS网关历史RSS峰值分别约100.8/117.3MiB、144.2/171.3MiB，收尾常规/关键队列均0、存储normal/core可用，RSS/FD回稳通过。Linux测试为本机无外网只读非root容器，2CPU/1536MiB，容器同时承载Python合成端；不是独立768MiB网关cgroup、Swift async task数或约1.6GiB目标宿主容量证据。Linux同一release二进制另通过protocol/WebSocket/Images全部受影响socket脚本；无新增Swift产品改动，不重复macOS已通过的175项与后端全集。既有前端43项、最终17项定向/构建和Linux静态构建沿用；最终Chrome账号全流程重新通过并等待抽屉卸载后捕获，主Agent已查看最终1440截图。

## 测试候选冻结

候选源码 `bd3896425d7cd47f6aaea95c9a616a9e06d46731`，schema v8；镜像中实际二进制与Linux socket验证产物逐字节一致（SHA-256 `55d76ab2b80f69885ff0fc0ec87c6877171aafdb1185a24befa42a856574acd4`）。`verify_installation.py --image codexone:desktop-test-candidate --previous-image codexone:v8-candidate --browser` exit0：私有初始化、非root只读运行、配置/实例锁/旧库迁移、持久Key、不同v8二进制同卷回退再升级和unknown责任保留、实际打包SPA Chrome登录/发Key/刷新/登出均通过。Chrome安装检查使用容器API relay，不称TLS；既有真实本地Nginx/TLS证据沿用，相关配置未变。

冻结目录 `artifacts/desktop-test-candidate/`（忽略，不提交二进制）：候选源码/镜像、不可变ID/二进制摘要、两平台有界报告及validation；一并保留已验兼容v8 peer的原精确源码/镜像与标识，旧v8归档不覆盖。SHA256SUMS逐项核对、候选镜像从归档重新load后ID一致。最终冻结记录只读集中review无新增P1/P2；文档/架构、差异格式及敏感信息检查通过。只在本地冻结，不推送/发行。使用步骤、合成矩阵与恢复原配置边界见[Desktop准备](../../development/desktop-preflight.md)。

真实Desktop UI、真实订阅/Images兼容和额度调用、M5恢复读取/缓存、完整O14/目标弱宿主、实际旧服务切换、远程CI与正式发布仍未验收。本轮未读取个人登录缓存、修改Desktop配置或调用真实订阅；进入真实Desktop前先讨论操作方式。
