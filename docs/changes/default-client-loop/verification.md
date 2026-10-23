# 默认客户端闭环 · 2026-10-23

全部验证为loopback合成模型/Key/正文、独立临时数据目录和全新私有客户端HOME/空工作区，禁用遥测；没有读取个人登录、调用订阅、推送或部署。平台macOS arm64，Swift 6.4，实际Desktop内置CLI `0.163.0-alpha.11.1`。CLI不是Desktop UI。

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

定向Swift首批7项通过；新增WS成功响应继承/替换/模型与ID边界用例随完整后端检查执行。socket脚本verify_lite验证两前缀JSON/SSE、原生WS预热与工具增量、顺序保留/包id移除、32 KiB UTF-8边界、HTTP compact Lite标识、未知/过量/重复声明和伪造call_id/previous拒绝；拒绝不能增加attempt/绑定/上游调用，跨连接不继承。缺失固定客户端的候选入口实际退出非零，未静默跳过。

完整后端、Linux定向出口和提交后review结果在完成后补记。

## 边界

本轮只闭合默认客户端正常操作与其安全声明边界。审计中的普通流事件/status矛盾、item.done/最终窗口一致性、HTTP SSE response关联、非法total_tokens提供者输出、首错误分类和健康归因等仍待下一“可信流与失败”闭环；本轮修正合成fixture的total并非完成通用用量输出校验。真实订阅握手/能力、Desktop UI、图片操作、M5恢复和O14容量未验收，线上候选未变更。
