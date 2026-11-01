# 验证与完成条件

定义构建和分层验证所需的证据、命令与适用范围。

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
| 协议 | HTTP/SSE/WS/桥接、Images generation/edits 的真实 socket 入口、标准/现有前缀、ID 屏障、lane/取消/错误 envelope |
| 缓存 | TTL/多级容量、加密、恢复契约、删除竞态、restore generation、备份排除 |
| 前端 | 类型/lint、权限表单、订阅额度/重置、按 Key 统计/趋势与错误筛选、浏览器截图与关键交互 |
| 发行 | Linux amd64 无凭证 CI、镜像非 root、弱服务器混合长压及低磁盘、升级/备份/恢复/回退与旧服务替代演练 |
| 真实兼容 | 显式授权账号与明确 Desktop 版本为主、CLI 补充；模型目录/文本/工具/预热/压缩/续接/出图/编辑逐项验证，不拿 fixture 当 live 证据 |

此文件维护检查定义及前提，实际运行结果、平台和局限随 PR 或活动变更报告，STATUS 仅维护公开状态。不要运行不存在的命令或把模板写成已通过；文档检查不需安装 Swift/npm 依赖。

实际报告必须包含命令、平台、结果、覆盖与未覆盖场景。kill -9 不等于掉电测试，Mac 不等于 Linux，缓存重播不等于上游恢复，CLI 成功不等于账号池隔离或财务正确。

真实Desktop验收须记录实际应用/版本、设备及模型/提供者选择、受控操作的界面结果，并与服务端请求UUID/固定拒绝原因或执行账本关联。不能把同Key/相近时间的成功预热或生成当成失败界面对应请求，不能将CLI、渲染网页或另一设备配置替代真实Desktop。电脑工具不允许操作目标应用时明确记录限制，不通过其他UI接口规避；需用户协作的一次操作应在诊断准备后进行，不要求无证据连续重试。

## 测试框架与入口职责

Swift Testing 按 Core/Adapters/Runtime/EndToEnd targets 分组；NIOEmbedded 测协议 handler，临时端口测实际 HTTP，进程脚本测配置、信号、部分启动失败和端口释放。前后端共用 `Tests/CodexOneAdaptersTests/Fixtures/system-status.json` 契约样例。SQLite/真实上游必须由各自实现追加测试，不能由健康入口推导。

前端使用 Vitest + Testing Library 测状态/校验和重试，Playwright 测真实浏览器的桌面/移动流程；浏览器测试可拦截合成 API。`scripts/verify.sh` 组合边界、格式、构建、各层测试；支持只验证后端或前端；浏览器项目区分配套 Chromium 与本机 Chrome，新建临时上下文，避免依赖用户浏览数据。设置 `PW_TEST_CONNECT_WS_ENDPOINT` 时 Playwright 与 `web/scripts` 的实际界面脚本改为连接外部浏览器（`web/scripts/browser-server.mjs` 启动），供无法启动 Chrome 的 macOS 沙箱贡献者使用。依赖安装、浏览器准备和运行命令见贡献指南，CI 使用锁文件，测试默认不读账号/外部上游。

默认客户端候选出口通过verify.sh的显式--client入口提供固定客户端路径及版本，缺少客户端或版本不符必须失败；不能以普通后端CI通过代替。脚本新建私有CODEX_HOME/空工作区、loopback合成身份及实际trial_provider序列化，分别验证默认内置目录/显式受信目录、文本三轮/工具往返/压缩续接与三种传输；断言客户端完成、实际传输无回退、上游次数与持久账本。默认路径通过--require-lite要求实际覆盖Lite工具包（可在WS预热中出现）。仅未支持web_search显式关闭，压缩场景显式降低阈值；不读取个人登录或修改个人配置。这是固定CLI合成兼容证据，不能替代Desktop UI或真实提供者。

## 发版 CI 验证边界

Verify 的 `changes` 用 Git diff 选择 PR 检查：Markdown、docs 和 LICENSE 只跑快速检查；web 选前端；Sources、Tests、Package、scripts 和 deploy 选后端；`.devcontainer` 选开发容器检查（构建镜像，在其中编译 codexone 并做前端类型检查）；`.github`、`scripts/verify.sh` 或未知路径选全部。混合修改取并集，重命名同时检查旧/新路径；main push 和手动运行总是选全部。独立 `docs` 始终检查文档、架构、分片完整性和容器版本一致性，包括开发容器与 CI 的 Swift digest、Node.js 版本一致。最终 `verify` 始终运行，要求所有已选任务成功，筛选跳过算成功；可将它设为稳定的 required check。

后端图为 `changes → backend-build → backend-scripts (1/4…4/4)`，前端在 changes 后独立运行。build 做格式检查、一次 `swift build --build-tests` 和串行 `swift test --skip-build`；四个脚本分片下载同一次构建的 codexone/ExecutionProbe tar（保留执行权限），其余脚本/合成 fixture 来自 checkout。分片不调用 SwiftPM。Swift build/shards 与 Dockerfile 固定相同的 6.4.1 digest；`.build` 缓存按容器 digest、锁文件和源码/测试散列区分，先恢复同锁文件、再恢复同工具链的增量缓存，未命中仍完整构建测试。所有运行都读取缓存，只有 main 推送在缓存未命中时保存，避免 PR 推送占满仓库缓存额度。

本地完整后端入口不变；单独复现分片需先构建，可覆盖二进制目录：

```sh
CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-build
CODEXONE_BUILD_JOBS=12 ./scripts/verify.sh --backend-scripts 1/4
CODEXONE_BACKEND_BIN_DIR=.build/debug ./scripts/verify.sh --backend-scripts 4/4
python3 scripts/backend_shards.py --check
python3 scripts/check_ci.py
```

分片清单在 `scripts/backend_shards.json`，按实测耗时分配；`verify.sh` 保留完整调用顺序，自检要求其中每个脚本恰好归属一个分片。新增后端检查时两处一起更新。

前端使用含浏览器/系统库的官方 Playwright Noble 镜像，不在每次运行时 apt/download 浏览器；镜像 tag 必须与 package-lock 中的 Playwright 版本一致，并固定 registry digest。e2e 用严格端口的 Vite preview 服务生产 dist；完整入口只构建一次，单独跑 e2e 前须 build，见[贡献指南](../../CONTRIBUTING.md)。

Dependabot 每周检查 Actions、npm、Docker 与 Swift 更新。Playwright npm 更新 PR 需维护者从 MCR 核验对应 tag 的 digest，同时更新 Verify 的镜像 tag/digest；`check_ci.py` 拦截版本偏离。Swift 更新需同时核对 Dockerfile、两个 Verify 容器与缓存 key；Actions 更新不能替代容器 pin 的维护。所有更新仍须通过相关验证。

Release 的 tag 流程和手动 dry-run 共用 Linux amd64 验证：verification target 的优化后二进制合成 socket/迁移失败检查、实际本地 TLS 反代和真实 OCI/Compose 安装。安装覆盖非 root/只读限制、SPA/auth/Key、锁、备份迁移与重启；旧 peer 参数可选，不默认构建固定 v8 历史镜像。需要旧二进制兼容或同库回退证据时，另外提供真实 peer 并运行定向演练。手动流程允许未发布 CHANGELOG，只上传产物；tag 流程须通过版本/主分支历史/CHANGELOG 检查后才可能发布，详见[发版规则](releasing.md)。

工作流/版本政策修改的本地检查：

```sh
python3 scripts/test_prepare_release.py
python3 scripts/prepare_release.py --dry-run --output-dir artifacts/release-policy
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7
python3 scripts/check_docs.py
```

这组检查验证 tag 格式、CHANGELOG 段落/预发布、真实本地 Git 祖先关系及工作流语法，不构建 Linux 镜像。源代码/安装包/许可归档与校验和的交付、推送后 digest/image ID 比对及来源证明只有实际运行 Release CI 后才有证据。未经明确授权，不运行真实订阅或部署验收。

## 首版替代验收记录要求

按 P11/P12、U10、C11、O13/O14 和 [项目范围](../../STATUS.md) 制作每次发行的验收矩阵，注明客户端/版本、模型/参数、端点/别名、传输/上游路径、用例与预期、实际结果及未覆盖项。合成失败测试与明确授权的真实 Desktop 流程分别报告；预热不是定时付费唤醒，图片编辑不是通用文件服务。旧服务 HTTP 200 或历史日志只能帮助确定基线，不能证明新实现结果等价。

额度验收覆盖主/次窗口、重置、观测失败/陈旧；统计验证跨 Key 隔离、时间边界、完整度、迟到更新及错误筛选。恢复验收逐项给出已知/未知执行、已有输出读取及客户端动作；不自动重执行是约束，不能据此省略实际兼容比较。

迁移演练使用独立数据目录与测试反代，验证账号身份、Key 保留/换发、域名/配置变化、存量会话和切回旧服务后的数据/凭证处理；不把首次安装成功视为迁移通过。容量验收记录参考宿主及共存负载、限制、持续时间、并发/大小包络与资源峰值/回稳，具体门槛见 O14；用户服务器上的真实切换必须另经授权。

## 相关文档

[文档导航](../README.md)
