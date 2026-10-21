# 验证与完成条件

## 当前唯一可运行检查

```sh
python3 scripts/check_docs.py
```

检查文档入口、本地文件链接、目录骨架及变更任务结构。不检查 Markdown anchor、远端 URL、协议语义或代码。通过只代表基础文档结构有效。

## 实现后逐步加入

| 范围 | 需要的证据 |
|---|---|
| Swift 基础 | 锁定工具链/依赖，严格并发编译、格式及有意义的单元测试 |
| 持久化 | 准入竞争、幂等结算、DB 不可写、kill 重启 pending/exposure、迁移/锁 |
| 协议 | HTTP/SSE/WS/Images 的真实 socket 产品入口、ID 屏障、lane/取消/错误 envelope |
| 缓存 | TTL/多级容量、加密、恢复契约、删除竞态、restore generation、备份排除 |
| 前端 | 类型/lint、权限表单及诊断流程、浏览器渲染截图与关键交互 |
| 发行 | Linux amd64 无凭证 CI、镜像非 root、升级/备份/恢复/回退、长压资源回稳 |
| 真实兼容 | 显式授权账号与 CLI 版本、脱敏结果；不拿 fixture 当 live 证据 |

建立相应实现时把真实命令和运行前提写到这里；当前不要运行不存在的 swift test/npm test 或向用户声称已完成。不要为了文档检查安装 Swift/npm 依赖。

实际报告必须包含命令、平台、结果、覆盖与未覆盖场景。kill -9 不等于掉电测试，Mac 不等于 Linux，缓存重播不等于上游恢复，CLI 成功不等于账号池隔离或财务正确。
