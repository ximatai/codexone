# 默认客户端闭环 · 2026-10-23

本地阶段全部验证为loopback合成模型/Key/正文、独立临时数据目录和全新私有客户端HOME/空工作区，禁用遥测；该阶段没有读取个人登录、调用订阅、推送或部署。平台macOS arm64，Swift 6.4，实际Desktop内置CLI `0.163.0-alpha.11.1`。CLI不是Desktop UI；后续明确授权的测试服务升级见末节。

## 真实客户端消费

```sh
./scripts/verify.sh --client --binary .build/debug/codexone --codex "$FIXED_CODEX" --expected-version 0.163.0-alpha.11.1 --require-lite
```

显式传入本机固定客户端路径，不把私人安装路径写入仓库。18组全部exit0，每轮turn.completed，无error/turn.failed。默认gpt-6.1-sol内置目录和显式受信目录分别覆盖HTTP直连、HTTP→WS桥接、原生WS；默认路径使用/backend-api/codex，显式目录使用/v1，socket回归另交叉两前缀。

| 每个目录 × 传输 | 用户操作 | 生成 | 预热 | 压缩 | 上游/settled |
|---|---|---|---|---|---|
| HTTP直连/桥接，文本 | 三轮，实际CLI resume两次 | 3 | 0 | 0 | 3/3 |
| HTTP直连/桥接，工具 | 工具调用、实际客户端结果、继续回答 | 2 | 0 | 0 | 2/2 |
| HTTP直连/桥接，压缩 | 工具结果、压缩、携上下文继续 | 2 | 0 | 1 | 3/3 |
| 原生WS，文本 | 同上三轮 | 3 | 3 | 0 | 6/6 |
| 原生WS，工具 | 预热声明、增量调用及结果续接 | 2 | 1 | 0 | 3/3 |
| 原生WS，压缩 | 同上并消费压缩窗口 | 2 | 1 | 1 | 4/4 |

合计30次用户操作、42次生成、10次预热、6次压缩，58次上游调用全部settled；输入/输出计量分别与实际非预热次数一致。脚本断言实际HTTP/WS线协议，无HTTP回退/隐藏重试，未用只收到HTTP200代替客户端消费。文本直接使用实际trial_provider.Handler，工具脚本仅选择一个合成工具输出并复用同一终态/事件序列化；默认工具调用clock.sleep 1ms，显式目录调用固定合成printf。web_search明确关闭，压缩测试显式低阈值和v2，不能称全部默认功能或真实提供者已支持。

首次验证先后发现并修正：additional_tools不支持；默认工具说明约14 KiB超过8 KiB；fixture缺total_tokens导致终态不能解码；原生WS预热后增量请求没有重复工具声明。最后一项最初触发HTTP回退，严格上游次数检查使其失败，完成同lane最近响应身份集合继承后才通过。

## 边界与回归

定向Swift首批7项通过，加入WS继承边界后8项由reviewer独立通过。socket脚本verify_lite验证两前缀JSON/SSE、原生WS预热与工具增量、顺序保留/包id移除、32 KiB UTF-8边界、重复HTTP compact Lite标识、未知/过量/重复声明和伪造call_id/previous拒绝；拒绝不能增加attempt/绑定/上游调用，跨lane/连接不继承。缺失固定客户端的候选入口实际退出非零，未静默跳过。

提交fc5f001后两名reviewer集中核查。Swift协议/权限无新增P1/P2；fixture/客户端测试发现两项P2并修复：HTTP compact使用固定上下文导致第二次503，改为本次epoch/sequence唯一值，两前缀连续compact证明不冲突；工具失败结果也可能让客户端最终完成，改为校验固定sleep成功结构或printf exit0及合成输出，压缩前也必须有成功工具证据。实际fixture的8组socket回归覆盖两种工具×普通/压缩×成功/失败，失败结果必须400且不能压缩；实际CLI完整18组按此收紧条件重跑。首轮完整后端停在重复compact失败处，不计为全集通过；修复后重跑，结果另记。

修复提交1f9c67d后，原reviewer确认两项P2均充分修复、无新增问题，并独立执行8组fixture正负向socket验证通过。主Agent重新执行完整18组实际CLI矩阵exit0，仍为58次上游/58 settled，无回退/额外调用且成功工具证据均被消费。

macOS arm64完整`./scripts/verify.sh --backend` exit0：格式/架构、build、197项Swift测试（35+35+3+124）及全部后端进程/socket/持久化/管理脚本通过，含新增fixture成功/失败证据、重复compact和跨lane不继承。133份文档结构、差异空白及新增文件私人路径/凭证模式检查通过；未修改前端，不重复前端全集。

## Linux发布二进制定向出口

```sh
docker build --platform linux/amd64 --target verification -f deploy/Dockerfile -t codexone:default-client-verification .
```

最终源代码为fc5f001，review脚本修复为1f9c67d，Swift 6.4.1/noble、native release单job、实际strip后的二进制；最终构建exit0。早期并行构建的上下文包含修复前fixture，同样捕获重复compact失败，不计通过；以最终脚本重建verification层后通过，复用完全相同的Swift Sources/Tests与编译层。

实际无网络权限的容器RUN覆盖protocol、websocket、lite、trial_provider、images、key_maintenance、snapshot_restore、storage_pressure和migration_cutback；Lite含同lane预热/增量工具结果、跨lane/连接拒绝，两前缀重复HTTP compact及28个WS/HTTP声明拒绝。fixture含8组工具成功/失败正负向。镜像经inspect为linux/amd64，标识`sha256:6f70e3458d928d4d0c5f13331bd2040c904ea8c5e134741a0fbf3da789d03881`；容器内实际二进制SHA256 `462d4a6ffead347e79ba51a5f11c27604f6d3f872b45e79a5511040d797accf1`。

这是本机Docker下的Linux定向发布二进制检查，不是Linux Swift测试全集、Linux实际alpha CLI、用户宿主容量、远端CI、完整runtime发行或部署验收。固定实际CLI矩阵仅在macOS执行。

## 边界

本轮只闭合默认客户端正常操作与其安全声明边界。审计中的普通流事件/status矛盾、item.done/最终窗口一致性、HTTP SSE response关联、非法total_tokens提供者输出、首错误分类和健康归因等仍待下一“可信流与失败”闭环；本轮修正合成fixture的total并非完成通用用量输出校验。真实订阅握手/能力、Desktop UI、图片操作、M5恢复和O14容量未验收。

## 后续明确授权的独立合成测试服务升级

2026-10-23，用户明确授权连接既有目标、升级之前部署的独立测试服务，再通知其操作Desktop；真实订阅、旧服务、个人客户端配置及推送发布不在本次范围。只读核对原运行源码ff1322f、固定loopback合成上游、真实账号为0、只启用所选原Key，原服务健康。

运行候选源码`363e7df8844b887bb6b4af8a2a1d5475175c77f6`（产品代码与本地出口相同），镜像`sha256:630659fe3dd6f832a29d9f9d2474353f99afb9948c5af4781653056e8e68113c`，实际程序SHA256仍为`462d4a6ffead347e79ba51a5f11c27604f6d3f872b45e79a5511040d797accf1`。本机标准多阶段runtime构建及`verify_installation.py --image codexone:default-client-candidate`通过，验证非root/只读、私有卷/配置、SPA/认证/Key持久化、锁、迁移及优雅重启；无需重复没有源码变化的全集。

精确源码/镜像/实际程序/摘要归档保留在忽略的artifacts/default-client-deploy，整体镜像归档SHA256 `fa581cd06ff08fb02a63ee321e273d5f0289819bd13f0acf9de9f73f054cdcc2`。基于旧完整归档仅传约14 MiB差量，目标重建完整归档后核对SHA，未以差量文件冒充运行产物。受控安装入口停止测试gateway/provider，完成并校验私有一致性backup bundle，保留旧镜像、配置与fixture供同schema回退，未恢复旧库或删除卷。原Key/地址/身份/管理员/模型配置及Nginx文件摘要保持。

首次替换fixture遗漏保留文件属主，非root提供者进程因权限拒绝启动，回退也受到同一属主问题影响；不记为成功。核对既有运行UID/GID后恢复旧fixture属主及旧测试版本健康，修正原子替换流程保留属主，再完成升级。新网关和fixture实际文件SHA、release manifest与候选一致，两容器healthy、无OOM/重启；升级前后Key/执行账本计数一致。

公网使用正常证书校验、独立临时合成Key，两个前缀HTTPS JSON/SSE、14 KiB Lite工具说明、WSS预热与previous增量续接、连续两次HTTP compact及非法声明拒绝通过；管理/健康路径不公开，缺失/错误Key拒绝。固定实际CLI用全新私有HOME/空工作区、默认gpt-6.1-sol无显式目录，分别在两个HTTP入口及既有前缀原生WSS完成两轮对话，6次用户操作均exit0/turn.completed，消费实际部署fixture固定合成终态。客户端没有读取个人登录或改个人配置。

最终持久记录精确为generation12、warmup4、compact4，共20次全部settled，无额外attempt；未知责任0、真实账号0。诊断Key已撤销且401复验，只剩所选原Key启用。Nginx及受保护配置/辅助文件摘要保持，旧服务container/image/启动时间未变并healthy。连接owner及私有操作材料只在仓库外保存，管理SSH在收尾时退出；不记录服务器、域名、Key名称或凭证。

本次准备好的是用户操作真实Desktop的合成入口，尚未将Desktop UI、真实订阅、M5或完整O14标通过；最终用户界面结果待其操作反馈。

部署记录提交4c9faf9后集中只读review无可行动事实或权限问题；reviewer独立核对本机binary/镜像归档/fixture指纹及20次计数与记录一致，源码相对运行候选仅文档变化。review未重复连接目标，远端事实依据主Agent保存的部署摘要；管理SSH owner已退出。

用户随后通知已发送。主Agent只读核对脱敏协议日志和所选启用Key的账本字段，不读取用户输入、凭证或完整admission正文：该Key出现2条执行，warmup及generation各1，均settled、outcome=succeeded、failure为空；全局unresolved为0，网关healthy、无OOM/重启，真实账号仍0。同期还有unsupported_tools/400拒绝日志，其中包含先前合成负向验证；剩余日志缺少主体关联，不能全部归因本次用户主请求，也不能因主请求执行成功就忽略潜在辅助流程兼容问题。尚未确认用户界面实际显示及其他操作结果，本次仅记录服务器执行成功，不标Desktop端到端或全部工具兼容通过；需用户确认界面固定合成回复。
