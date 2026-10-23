# 验证记录 · 2026-10-23

实现 `ed399bb`，受控源转换 `adf85c8`。主Agent亲自实现、调试、定向测试、出口及已授权旁路部署；两位subagent集中review、源转换增量复核均无新增P1/P2。未修改旧服务、账号授权或原客户端配置，新侧没有订阅账号或真实生成调用。

## 本机与跨平台

- macOS arm64：完整后端180项Swift及当时全部后端脚本通过，含新离线摘要导入和合成fixture；源转换随后新增，以独立定向回归验证，不重复已通过全集。文档/架构/格式与差异隐私检查通过。
- Linux amd64：Swift6.4.1优化构建；在禁外网、只读、非root、512MiB/2CPU/pids128的隔离容器中，源转换、Key导入、合成fixture、原Key治理双传输及生产pool配置通过。临时盘128MiB首次被256MiB可选写入保护正确拒绝；改1GiB测试临时盘后通过，未改变保护阈值。
- 导入实际进程测试：完整清单验证先于建库；拒绝坏摘要/字段/重复ID与摘要/管理员冲突/停用/任何有效期/未核对策略/陈旧与未来采集/权限/链接/超容量。默认全部禁用，运行实例/重复导入/实际空快照恢复态拒绝；第二行SQLite注入失败时第一行及审计一起回滚。真实HTTP/WS仅显式CAS启用的一枚合成旧格式Key可用，其他拒绝；重启/轮换不重置限额，轮换后旧字符串失效，无原文落库或输出。
- 源转换测试：固定已核对列集合，未知schema拒绝；只读事务、源文件未变；模型取批准交集，停用/有效期/强制模型或推理/绑定/传输/非前台/不可表达模型等逐项隔离，所选Key不唯一或不合格整次拒绝。输出新0700目录及独占0600文件，摘要不进映射/隔离记录或终端；等价声明是管理员审核，不是自动证明。
- 合成fixture实际socket验证HTTP JSON/SSE、HTTP→WS桥接/native WS、compact、固定输出不回显输入，以及空闲WS收到SIGTERM后中断并等待owner退出。初版测试把有Authorization的客户端直接接无凭证fixture而拒绝，修正夹具；没有修改产品认证逻辑。

## 已授权旁路与入口

独立候选 `codexone:key-trial-candidate`，源码 `adf85c8f20cd113b7e09e38d55eb336993ee82fa`；镜像ID `sha256:1d5f847fe907e75d96f1ae5bdd439c13760dfc862db30e3d00aa5eccbcaf36bc`；Linux程序SHA256 `28e31778b6c278aefd3934d7f5f46593b70f8ed89007847c02ab56310314ed62`。镜像与本机受测产物、实际目标运行程序逐字节摘要一致，旧候选保留。

用户明确批准独立旁路+保留原Key+首轮单Key合成模式后，主Agent在目标服务器内只读核对源验证算法与所选Key/模型/客户端类型元数据；不读取请求正文、账号凭证或原Key明文。经过严格源转换，清单留在私有目录并在新目标同事务禁用导入。只启用用户选定Key；真实所选Key的客户端请求尚待用户操作，不能用验证摘要匹配冒充该验收。独立测试限额不是旧余额，撤销与用量不自动同步。

部署使用新私有目录/卷/管理员凭证、非root/只读容器和合成上游，经既有安装命令包装器固定project/volume/env选择；普通Key不能访问管理。临时生成的诊断Key完成实际HTTP与native WS固定回复后被撤销，再启用所选Key。新库账号数与unknown均为0；所有导入摘要与私有源清单一致、只一枚活动Key；旧服务容器/镜像标识未变且健康，卷不共享。未切旧入口、反代、DNS或防火墙。

目标Docker不支持CPU CFS硬配额，初次创建拒绝时未启动旁路服务；核实后使用同一单核CPU集合，保留硬memory/swap/PID限制，并读取实际cgroup memory.max/memory.swap.max/pids.max/cpuset确认生效；不是CPU CFS配额或独占核。合成fixture在初次样本后提高小幅内存余量并复核健康。真实目标只证明低流量合成部署，不计完整O14或实际订阅容量。

数据/管理/fixture监听均实际核对为loopback；只经受控SSH通道接入本机。无会话转发曾被远端关闭，改为有明确owner、保活与一小时期限的会话后跨独立请求保持可用。主Agent用独立Chrome实际访问已部署打包SPA：同源登录、Secure/HttpOnly/Strict cookie、导入列表/单Key状态和退出通过；等待初始会话读取完成后操作，未放宽Cookie/CSRF或浏览器全局信任。未保留含实际Key标识的截图，未操作个人Desktop配置。

服务器地址、连接别名、安装路径、选定Key名称/映射、源清单与管理凭证仅私下保留，不进入仓库；忽略产物目录只保留公开源码/镜像/合成验证与脱敏核对结果。

## 保留项

下一步用户在独立客户端新会话切测试地址、保留原Key，核对实际协议/失败路径。当前只回明确合成提示，不执行用户工具任务；真实Desktop操作、真实订阅调用、正式切换/账本核对、M5及完整O14均未完成。服务端网关/管理/fixture仍监听loopback；后续授权的公开数据入口见下，客户端无需重新建立SSH隧道。

## 2026-10-23 独立公网HTTPS出口

主Agent配置独立数据域/公共证书与ACME webroot，复用交付数据路由片段，管理保持回环；不修改旧服务路由、容器/镜像或已存在的Nginx文件（逐一SHA核对）。交付 `090d742` 后集中subagent review无新增P1/P2；程序/镜像及schema未变，不重复完整后端和前端验证。

- macOS arm64 / Linux amd64交付数据专用模板实际Nginx配置检查通过。Linux隔离客户端正常验证公网证书链/主机名，两条Responses路径的JSON/SSE/WSS完成固定合成回复，缺失/错误/撤销Key为401，管理/健康/根路径404，HTTP固定域跳转308。
- macOS首轮默认网络路径WSS握手超时；服务器回环TLS和Linux公网WSS均通过。随后macOS直连公共地址、保留原域名SNI/正常证书校验，同组JSON/SSE/WSS及拒绝路径通过；未定位首轮网络超时根因，不写成默认路径WSS已复现通过。
- 每次公网检查只用新建诊断Key，不读取原Key明文；首次收尾SSH中断后立即重新连接撤销，后续诊断均撤销，最后仅所选源Key启用，unknown=0、旧服务healthy。真实账号/订阅未配置，原Key客户端操作仍待用户。
- 独立证书的webroot与校验成功后reload hook已保存，现有Snap续期timer active；首次检查了错误单元名导致新配置安全回退，核实实际timer后加载成功。临时客户端隧道owner已退出，不影响私有管理SSH。

续期实际执行 `certbot renew --cert-name <独立域> --dry-run --run-deploy-hooks --no-random-sleep-on-renew --non-interactive` exit0，验证staging HTTP challenge及配置检查/reload hook。首次长SSH中断、随后受控后台worker遇到Certbot随机延迟；仅终止本次owner进程组，取消随机等待后完成，不改变既有续期timer。私有运行证据留在部署目录，不入仓库。

## 2026-10-23 用户首轮Desktop合成请求跟进（未通过）

用户界面显示重连5/5与通用网关错误。只读检查网关及fixture健康、无重启/OOM；所选源Key没有执行或持久拒绝记录，因此不能断言认证通过、请求已准入或上游失败，也不能以此前诊断Key公网验证替代此次客户端验收。

准备临时入口诊断，仅固定schema的HTTP状态、上游状态、GET/POST/other方法枚举、WS布尔、时长与Nginx随机请求ID；无正文、认证头或路径。私有文件、owner定时检查约64KiB截断、最长600秒后恢复本次自有配置并先检查后reload；不修改旧服务配置。自有未认证探针401及诊断schema检查通过。实际请求失败码仍需用户重试/客户端安全错误详情，不放宽权限/解析契约，不开启真实订阅。

## 可选reasoning修复的定向证据

只读CodexLB固定快照中ResponsesReasoning可空成员及model_dump_for_forwarding(exclude_none=True/保留tools缺省)后，主Agent修复仅这两个已知成员的null处理。macOS arm64新增2单测，以及实际两前缀HTTP JSON/SSE、桥接/native WS、同socket预热后生成通过；记录合成上游实际收到的reasoning和tools存在性，确认null已移除、显式值保留、缺省tools与[]不同。错误类型及未知成员不连接上游/不创建attempt，全部正常执行最终settled。原拒绝日志/首帧错误/隐私与上限实际进程回归通过。

运行候选剥离调试段的无网络SDK试验将同一程序从约114MiB降为约44MiB，正式候选仍须用剥离后的程序验证并记录SHA。没有因为体积优化而改编译优化等级、运行权限或持久语义。

当前修复提交 `bdb67f4` 集中subagent review未发现新增P1/P2。macOS arm64完整 `./scripts/verify.sh --backend` exit0，184项Swift测试及全部后端脚本通过；不是只运行新增两项。Linux实际候选与公网部署结果另记，不以本机通过代替。

Linux amd64优化候选 `bdb67f4edd454a86f3893fd6164159b62609b965`：镜像ID `sha256:24aaa77264142d45ce875cbb181f2c8054c475826fdaed72716ba96acb81fb22`，实际剥离调试段后的程序SHA256 `8735ced3596e8a04797d661e0078f0d5a1814e3225b19190c4bfc566a63e0838`（46,534,632 bytes）。在无外网、只读、非root、512MiB/2CPU/pids128、1GiB私有临时盘中运行optional_reasoning、protocol_rejections、protocol、websocket、trial_provider五组实际进程/协议检查，全部exit0；本轮Linux不是完整Swift单测全集。没有前端产品变更，不重复UI全集。

首轮Linux构建随本机Docker守护进程重启以EOF中断；未确定重启原因，不计通过。守护进程恢复后复用缓存重建成功，没有重跑已通过的macOS全集，也没有重启或修改服务器旧服务。本机镜像归档119,001,600 bytes，SHA256 `edd0ac1f3d67d06c22389b6c9fcf7d641ab11fd7c13b078ccddf837fef5caa31`；与旧已验证归档共享的内容复用，差量14,370,895 bytes，按固定来源/偏移/长度重建并校验完整SHA，不能以差量自身摘要代替镜像一致性。

候选已在已授权新侧部署，目标重建完整归档及运行程序SHA均匹配；新配置/管理员/身份未变、旧服务容器/镜像未变healthy。公网正常信任校验，两前缀JSON/SSE/WSS与同socket预热、三种已知null组合200，错误类型/未知成员400，401/撤销Key及管理404、HTTP308通过，诊断Key最终撤销。更新后用户再次发送仍得到unsupported_reasoning/400，所选Key无attempt、unknown=0；不标Desktop通过，继续固定原因分类，不推断客户端原字段值。

四项可空控制及固定reasoning拒绝原因（`9acf3e3`）：主Agent7项定向Swift、扩展实际HTTP JSON/SSE/桥接与native WS/预热最终文档及负向不派发、固定枚举/公开envelope不变/16条上限及隐私通过，提交后集中review无新增P1/P2。macOS arm64完整187项Swift及 `./scripts/verify.sh --backend` exit0；Linux新候选/公网诊断仍待本轮后续记录，不提前宣布客户端通过。

Linux新候选最终绑定正确源码 `9acf3e3007c56a4047e8d136870dcc2b22190750`，发布revision录入错误在导出前纠正并复用相同后端缓存；实际剥离程序SHA256 `0e1af00159fd57f45cc8c21434bf7766011465d479deb00fb9a96a2892b34fef`，镜像ID `sha256:ed1982b180148c4040765a7d889da3eff5131b3f9fe33cfd0626f4b5ace47677`。同样无外网/只读/非root/512MiB/2CPU隔离：参数、拒绝诊断、HTTP协议首轮通过；WS全部业务断言后在最后网关退出码断言失败，原断言未保留具体码。只重跑WS失败组并补非零退出采集后通过，尚未执行的fixture随后通过；首轮原因未确认，不冒充一次全集全绿或已修复退出根因。未重跑已通过三组，无前端变更。归档SHA256 `91755cc863b89f3a08e525394fde726d5d9c024b2a04b0e6e98c6446f076c72d`。

四项控制候选公网双前缀JSON/SSE/WSS/预热、已知nullable组合、负向参数/认证/管理隔离通过；运行SHA匹配，配置及旧服务未变，诊断Key撤销。用户再次失败固定原因reasoning_members，unknown=0；这仅确认额外成员，不输出字段名或参数原值。按官方客户端发送结构增加context三枚举及summary delivery单枚举，9项定向Swift与实际四传输/预热最终文档和负向无派发通过；新候选尚待Linux/部署，不写实际Desktop通过。
