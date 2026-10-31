# Desktop 图片闭环对齐验证

日期：2026-10-30。平台：macOS arm64，Swift 6.4.2（Xcode 工具链）。仅使用本机回环合成上游、合成图片容器、临时账本和临时 Key；无真实账号调用、推送或部署。

## 命令与结果

- `swift build`：退出码 0，`Build complete!`。
- `swift test 2>&1 | tail -20`（启用 pipefail）：退出码 0，211 项通过（35 Core、36 Runtime、3 EndToEnd、137 Adapters）；末行 `Test run with 137 tests in 1 suite passed`。
- `./scripts/verify.sh --backend`：退出码 0，文档/架构/格式、Swift 211 项及所有后端合成脚本通过；末行 `PASS: synthetic independent legacy backup/drain, unchanged route/prefix, explicit Key replacement and conservative baseline; actual gateway settled/unknown interval preserved on audited cutback without replay`。首轮曾因 Lite 夹具沿用 8 MiB 请求上限失败；同步到 32 MiB 后完整重跑通过。
- 定向 `python3 scripts/verify_images.py --binary .build/debug/codexone`：退出码 0，HTTP 与 websocket 两组 PASS。
- 定向 `python3 scripts/verify_websocket.py --binary .build/debug/codexone`：退出码 0，含分片、FIFO、断线取消及关闭 owner 检查。
- `swift format lint --strict --recursive Sources Tests Package.swift`、`git diff --check`：退出码 0。

原始默认构建分别遭遇模块缓存目录不可写与 sandbox-exec sandbox_apply 拒绝。实际成功命令将 CLANG_MODULE_CACHE_PATH、SWIFTPM_MODULECACHE_OVERRIDE 指向临时目录，并按 brief 使用 --disable-sandbox。为让 verify.sh 内部的 build/test/package 命令使用同样选项，PATH 中仅为本次验证加入临时 swift 包装器；仓库验证脚本、Package.swift、Package.resolved 和依赖镜像配置均未改动。现有 SwiftPM 镜像身份冲突及既有 Codable 常量警告不影响退出码。

## 新增证据

- HTTP 两种上游传输下，含视觉历史的独立 compact 和流式 compaction_trigger 成功派发；无视觉权限仍为 403 model_not_allowed。原生 WS 含图流式压缩成功，无视觉权限仍拒绝。
- Images 的 user、参考图 detail、mask detail 在合成上游工具声明中不存在；缺失/错误类型的 image_url、17 张参考图拒绝，16 张成功。16 张各 9,000,000 像素的参考图成功，证明已移除总像素上限；单图超过 50,000,000 像素、超过 16 MiB、参考图合计超过 24 MiB 均在派发前拒绝。
- 20 MiB Responses 经 HTTP 和原生 WS 成功；HTTP 声明超过 32 MiB 为 413，WS 超限单帧及分片拒绝后仍可继续消息。
- 三个 Content-Length 32 MiB 上传占满共享 96 MiB 预算，第四个及 chunked 超过 8 MiB 时返回 503 capacity_exhausted、Retry-After: 1；提供者调用数与持久 intent 数不增加。半截上传断开及 10 秒读取超时后，大请求再次成功。
- HTTP 与 WS 共用同一预算：HTTP 占满预算时 WS 返回 status 503 并丢弃消息，归还后同一 WS 连接可成功派发。
- Swift 嵌入式帧测试以较小预算验证：单帧在正文到达前预留、分片增量拒绝、消息丢弃、连接关闭回收、完成正文租约持有及重复释放幂等。
- 两个授权且声明 imageGeneration 的对话模型均使用同一图片模型；未声明能力的对话模型、未授权图片模型拒绝，目录能力计算与执行一致。

## 所有权与内存边界

ResponsesDataService 拥有共享预算并注入 HTTP 读取和下游 WS 帧读取；无全局可变预算。超过 8 MiB 时计入整个正文，而非只计超出部分。已知长度在正文缓冲前申请，chunked 与分片递增申请。租约随 WS 正文进入 inbox/调度队列，派发结束清空原始正文并归还；异常、断开、读取超时、连接关闭走相同释放路径。预算不足不等待。

96 MiB 是原始大正文预算，不是 RSS 上限。32 MiB JSON 在解析/转发中通常同时有原始 Data、JSONDecoder/字符串树、重新序列化缓冲和上游传输缓冲；WS 另有帧到 Data 的复制及 create 解包后再次编码/解码。保守按约 4—8 份同量级载荷估算，单个最大请求约 128—256 MiB，加对象、分配器和图片解码后数据；这不是实测峰值承诺。小于等于 8 MiB 的正文不占此预算，受现有连接/队列容量约束。多个大请求并发仍可能显著高于 96 MiB；尚未验证弱宿主 RSS 峰值。容器头校验不做栅格解码。

## 未验证范围

- TLS 反代与显式长耗时 Desktop boundary 脚本已同步新上限，本阶段未运行这两项额外出口。
- 本阶段未执行 Linux 新候选构建/verification；不能用旧缓存镜像代表本次变更。
- 未运行真实 Desktop 图片生成、参考图连续编辑与含图会话自动压缩；需后续授权验收。
- 未修改 STATUS.md、web/、Package.swift、Package.resolved；未执行 git add、git commit、push 或 PR。
