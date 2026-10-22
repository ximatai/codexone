# 验证

## 2026-10-22 · 主 Agent 实现与定向验证

平台 macOS arm64 / Swift 6.4，Node 22.23.0。本轮全部使用合成身份、有效合成 PNG/JPEG/WebP、loopback 提供者与独立临时 SQLite；没有真实账号或额度调用。

- `swift test --filter 'poolImages|v5Image|image|Image|multipart|legacyKeyMetadata|Usage'`：21 个测试函数通过。覆盖权限组合、原子复核、旧策略默认关闭、v5 离线备份迁移/重复迁移、模型映射、合法容器与截断/损坏、mask、JSON/multipart、终态/部分工具用量、只读统计及托管池 HTTP/桥接/原生 WS 同账号续接、跨主体拒绝、intent 数与调用数一致。
- `npm --prefix web run build`、`npm --prefix web test -- --run`：类型/生产构建、34 项测试通过，新增仅图片 Key 不授予对话/视觉权限的表单回归。
- `python3 scripts/verify_images.py --binary .build/debug/codexone --browser`：真实 HTTP/SSE/multipart、两种前缀、下一次主动编辑、权限矩阵、跨主体图片 ID、桥接与原生 WS、终态后完成、错误/断流/未知用量、不重放；实际 Chrome 1600×1100 临时上下文操作生产 SPA/真实管理 API，创建仅图片 Key、执行允许/拒绝、修改独立权限、生成关闭仍可视觉输入、用量指标。已查看脱敏全页截图，未见横向溢出或秘密残留。

新增故障注入及最终集中 review/阶段出口结果在实际完成后追加。代码编译初期的测试宏缺少 try、测试 SQL 使用了错误列名均已修正；默认 Xcode SwiftBuild 产物曾残留签名临时文件导致 codesign 失败，移除该次生成的临时文件后重试通过。这些失败尝试不计入通过证据。

## 支持范围与缺口

- 图片正文仅瞬时有界驻留；容器校验不作栅格解码，不证明真实提供者接受。fixture 为可解码合成图片，未以伪造头部或任意 base64 代替成功验收。
- 图片与 compact/stream compaction 的组合在派发前拒绝；未验证图片历史压缩适配。
- Desktop 实际出图/参考图/连续主动编辑及真实订阅上游兼容未验收，继续保留，不以 Chrome 管理 UI、CLI 或合成协议证明它们完成。
- 未推送、运行远端 CI、发布或部署；Linux 与完整阶段出口尚待集中 review/修复后验证。
