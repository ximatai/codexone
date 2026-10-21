# 验证与完成条件

## 文档检查定义

```sh
python3 scripts/check_docs.py
```

检查稳定文档入口、本地文件链接及变更任务结构，不锁定业务目录或某个活动提案名。排除依赖/构建产物，不遍历 node_modules/.build。不检查 Markdown anchor、远端 URL、协议语义或代码。通过只代表基础文档结构有效。

## 各层验收要求

| 范围 | 需要的证据 |
|---|---|
| Swift 基础 | 锁定工具链/依赖，严格并发编译、格式及有意义的单元测试 |
| 持久化 | 准入竞争、幂等结算、DB 不可写、kill 重启 pending/exposure、迁移/锁 |
| 协议 | HTTP/SSE/WS/Images 的真实 socket 产品入口、ID 屏障、lane/取消/错误 envelope |
| 缓存 | TTL/多级容量、加密、恢复契约、删除竞态、restore generation、备份排除 |
| 前端 | 类型/lint、权限表单及诊断流程、浏览器渲染截图与关键交互 |
| 发行 | Linux amd64 无凭证 CI、镜像非 root、升级/备份/恢复/回退、长压资源回稳 |
| 真实兼容 | 显式授权账号与 CLI 版本、脱敏结果；不拿 fixture 当 live 证据 |

此文件维护检查定义及前提，实际可运行入口、覆盖/未覆盖与最新结果只在 STATUS 维护。不要运行不存在的命令或把模板写成已通过；文档检查不需安装 Swift/npm 依赖。

实际报告必须包含命令、平台、结果、覆盖与未覆盖场景。kill -9 不等于掉电测试，Mac 不等于 Linux，缓存重播不等于上游恢复，CLI 成功不等于账号池隔离或财务正确。

## 测试框架与入口职责

Swift Testing 按 Core/Adapters/Runtime/EndToEnd targets 分组；NIOEmbedded 测协议 handler，临时端口测实际 HTTP，进程脚本测配置、信号、部分启动失败和端口释放。前后端共用 `Tests/CodexOneAdaptersTests/Fixtures/system-status.json` 契约样例。SQLite/真实上游必须由各自实现追加测试，不能由健康入口推导。

前端使用 Vitest + Testing Library 测状态/校验和重试，Playwright 测真实浏览器的桌面/移动流程；浏览器测试可拦截合成 API。`scripts/verify.sh` 组合边界、格式、构建、各层测试；支持只验证后端或前端；浏览器项目区分配套 Chromium 与本机 Chrome，新建临时上下文，避免依赖用户浏览数据。依赖安装/浏览器准备与可运行命令查根 STATUS，CI 使用锁文件，测试默认不读账号/外部上游。
