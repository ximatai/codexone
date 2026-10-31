# 上游 WebSocket 空闲关闭验证

日期：2026-10-31。仅合成数据、loopback socket 与临时 SQLite；不调用真实账号、不部署、不提交。

## 覆盖与证据

- `verify_websocket.py`：单身份上游正常关闭帧与 TCP EOF，完成一轮后下游 5 秒 socket 期限内收到 1000；关闭后、读取下游关闭帧前发送 create，执行数、拒绝诊断数、unknown 数不增加，上游调用只增加原一轮。新连接正常完成下一轮。
- 同一脚本：在途 turn 被合成屏障挂起，同 lane 提前排队 create；上游关闭后排队请求不 dispatch，原 turn 收敛为 unknown。另一 lane 已完成且空闲时重复此流程，账本保留 settled + unknown，不重放。既有多 lane 已读终态/EOF、非法上游 lane、在途断线、桥接与取消回归继续运行。
- `poolNativeWebSocketUpstreamCloseDrainsAndRejectsQueuedCreates`：真实 RFC6455 子进程客户端、合成账号池上游；空闲/另一 lane 在途、同 lane 排队与关闭后 create 均覆盖，收到 1000、无拒绝诊断、仅原在途执行 unknown，finalizer 与上游 channel 收敛，新连接成功。
- `verify_request_parameters.py`：`include` 同时含 `reasoning.encrypted_content` 与 `output.encrypted_content`，按完整数组及顺序核对提供者收到的值；Responses 与 Codex subscription 两种契约、HTTP JSON/SSE、HTTP→WS 桥接及 native WS 均覆盖。

关闭通知由上游 reader 持有，连接任务组等待 lane/首执行 owner 退出并交接最终化责任后发送 1000；持久结算由既有独立 finalizer 异步完成，测试另等待账本收敛，不让连接反向等待持久 worker。

## 命令结果

平台：macOS arm64，Apple Swift 6.4.2，debug 候选。

| 命令 | 退出码 | 关键结果 |
|---|---|---|
| `swift build --disable-sandbox` | 0 | `Build complete! (2.68秒)` |
| `swift test --disable-sandbox 2>&1 \| tail -20`（pipefail） | 0 | 四 target 共 224 项（35 + 42 + 3 + 144）通过 |
| `swift format lint --strict --recursive Sources Tests Package.swift` | 0 | 无诊断 |
| `python3 scripts/check_docs.py` | 0 | 173 个 Markdown 文档、本地链接与变更结构通过 |
| `CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend` | 0 | Swift 224 项与全部注册后端脚本通过；WS 关闭/竞争、119 项参数矩阵、图片/迁移/控制/维护及迁移切回均通过 |
| `git diff --check` | 0 | 无空白错误 |

Linux amd64：Docker `deploy/Dockerfile` 的 `verification` target 全部通过，退出 0（release 构建及全部注册 socket/维护脚本）；固定 Swift 6.4.1 镜像、本地只读 SwiftPM 镜像、既有公开 Ubuntu 镜像源与 12 个构建 job；验证 RUN 使用 `--network=none`，只访问 loopback 合成提供者。

一次并行 Swift 测试与 Linux release 编译同时运行时，握手拒绝测试 `poolWebSocketUpgradeRejectionsClassifyHealthBeforeAnyCreateAndNeverReconnect` 出现 401 健康状态/unknown 断言失败（退出 1）；未修改该测试，独立复跑退出 0，随后上述完整 Swift 测试退出 0。原因尚未定位，保留为并行验证不稳定风险。初次 buildx 因沙箱外活动目录写入被拒而退出 1，改用临时 `BUILDX_CONFIG`；默认 Ubuntu 源准备缓慢的构建已取消（130），沿用既有构建的镜像源参数后重跑。实现收尾后取消了一次尚未完成的后端验证（130），以上表中最终候选完整复跑为准。

等价 Linux 入口（本地路径使用占位符）：

```sh
BUILDX_CONFIG=<TEMP_BUILDX> docker build --platform linux/amd64 --target verification \
  --build-context swiftpm-mirrors=<MIRROR_ROOT> \
  --build-arg SWIFT_BUILD_IMAGE=docker.m.daocloud.io/library/swift:6.4.1-noble@sha256:19cbe56bdaec1918f7cf5fdeba42b9bd55bdd8a6149c9990d0e0e3a89a127d63 \
  --build-arg APT_MIRROR=http://mirrors.aliyun.com/ubuntu --build-arg BUILD_JOBS=12 \
  -f deploy/Dockerfile .
```

## 边界

真实 Desktop、真实订阅上游的空闲关闭/一小时寿命、网络设备断连仍需部署后经授权观察；本阶段没有部署或真实额度调用。Linux verification 仅证明其注册脚本的合成范围，未运行 Linux Swift 测试套件。HTTP→WS 桥接未增加连接重建或重放。
