# 验证

## 2026-10-22 · M4 本地合成阶段出口

全部使用合成身份、有效合成 PNG/JPEG/WebP、loopback 提供者与独立临时 SQLite，没有真实账号或额度调用。主 Agent 亲自实现、验证和修复。

| 平台 / 快照 | 实际验证 |
|---|---|
| macOS arm64 / Swift 6.4 | `70f9214` 的 `./scripts/verify.sh --backend` 完整通过（151 Swift 测试及全部脚本）；最后用量/WS 关闭修复后，`fd3e28d` 的 `swift test --no-parallel -j 4` 全部 152 项通过，受影响 `verify_images.py --browser`、`verify_websocket.py` 通过，格式检查通过。未重复无改动的其他脚本。 |
| Linux amd64 / Swift 6.4.1 | `fd3e28d` 精确代码快照完整 `./scripts/verify.sh --backend` 通过：152 Swift 测试与全部进程/SIGKILL/迁移/HTTP/SSE/WS/context/压缩/图片/Key/session/账号/池配置脚本，exit 0、无 OOM。独立本地容器、2 CPU / 2500 MiB、单并发、native 引擎、开启索引、Swift 每批至多 16 文件，Swift Testing 执行，禁用 XCTest；重用无凭证依赖缓存。容器已回收，缓存保留。不是弱服务器容量、远端 CI 或生产验收。 |
| 前端 / Node 22.23.0 | `./scripts/verify.sh --web --chrome` 类型/生产构建、35 项测试、3 项 Chrome 场景通过。实际 Chrome 1600×1100 临时上下文操作生产 SPA/真实 SQLite API：仅图片 Key 创建、目录/生成/对话允许拒绝、修改权限后生成关闭而视觉输入仍可用、图片工具 token 与用量状态显示；已查看脱敏全页截图，无秘密残留或横向溢出。 |

关键新覆盖：两种路径前缀、JSON/multipart/参考图/mask、下一次主动编辑、独立权限/宿主映射/原子 revision 复核、旧策略默认关闭、v5 显式私有备份迁移、跨主体图片 ID、托管池 HTTP/桥接/native WS 同账号续接、一次调用一个 intent；预览/项完成不抢先完成，畸形/缺失工具指标、失败/不完整终态、慢提供者、声明超大正文、原生 turn 撤权、绑定失败、关闭与取消均不跨账号重放。HTTP 整包在绑定失败前已有用量可结清；WS 若在 created 绑定处失败、未收到终态用量则保留 unknown，不制造同等证据。

## 集中 review、复审与故障修复

`ee8d300` 提交后由后端和前端 subagent 集中只读 review；主 Agent 以 `70f9214`、`fd3e28d` 修复，复审关闭：

- 48 模型容量同步到健康读取、统计 options 和前端 DTO；完整 48 冷却回归防止合法状态误报核心存储故障。
- 仅可信 completed 可确认零图片调用并结清；failed/incomplete 空 output 或缺失工具指标保持 partial/unknown。畸形工具指标仍保留可信宿主用量下界。
- 目录的图片能力按宿主与有效图片映射求交；显式非字符串 model 拒绝，真实 socket 验证不派发。
- 最终回归实际捕获 Inbox 持锁恢复 continuation 与取消的锁反转，采样定位后将所有恢复移到锁外；64 轮并发取消/结束、真实关闭脚本及完整 Swift 回归通过。该次挂起已终止，不计通过。
- Images 流式事件补齐 created_at/size/quality/background/output_format，返回格式按[官方事件契约](https://developers.openai.com/api/reference/resources/images/generation-streaming-events)校验；缺失工具用量不伪造零。

编译期间测试宏/夹具列名错误、SwiftBuild 签名临时产物失败和 SSE 夹具误解析 `[DONE]` 均已修正，失败尝试不计通过。全局状态只在 STATUS 维护。

## 未覆盖与支持边界

- Desktop 实际出图、参考图/连续主动编辑与真实订阅提供者兼容未验收，不以 Chrome 管理 UI、CLI 或合成协议替代；完整 M4 客户端出口未关闭。
- 图片与 compact/stream compaction 组合在派发前拒绝；未验证图片历史压缩适配。容器校验不作栅格解码，不证明真实提供者接受。
- 不持久保存图片或 prompt；没有真实账号调用、推送、远端 CI、发布或部署。弱服务器混合容量留给 M6。
