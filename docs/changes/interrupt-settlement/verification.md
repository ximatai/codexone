# 验证：中断后断开时续读上游终态

日期：2026-10-31。环境：macOS arm64；仅本机合成 socket/账号数据，不调用真实提供者。

## 覆盖

- `verify_client_protocol.py`：中断转发后下游断开，终态用量结算为 settled（输入5、输出3、估算8）；8条续读占满连接槽，结束后新连接可用。
- 上游 EOF、10秒无终态、未中断断开保持 unknown；检查 create 数量不增加，不重放。原执行期限2秒时不延长至10秒。
- 混合 lane：首轮未中断取消不终止已中断 sibling；运行时停止在5秒内取消续读并退出，未知责任保留。
- 三个已知 Desktop 头在合成上游握手中收到，日志无对应未知头 warning。
- `verify_websocket.py`：原有终态/EOF并发、空闲正常关闭、队列不派发、lane FIFO、正文与连接取消回归；账号池 Swift socket 测试覆盖握手中/在途断开和运行时取消。
- 定向 Swift 测试：中断标记不跨响应复用；取消单个 inbox/关闭等待者不取消其他 lane/等待者。

## 最终验证

- 完整 `CODEXONE_BUILD_JOBS=12 CODEXONE_SWIFTPM_DISABLE_SANDBOX=1 ./scripts/verify.sh --backend`：退出码 **0**，耗时 **505.88秒**。Swift 四个测试 target 分别35、43、3、151项，共232项通过；全部后端合成脚本通过。
- 沙箱内额外设置 `CLANG_MODULE_CACHE_PATH` 与 `SWIFTPM_MODULECACHE_OVERRIDE` 为 `$PWD/.build/clang-module-cache`，不修改 Package 或验证脚本。
- 关键输出：`PASS: interrupted disconnect settles usage; retained connection capacity; EOF/10s timeout/no interrupt remain unknown without replay; resources release; shutdown cancels drain; known headers forward without warnings`；`PASS: interrupted settlement retains the original shorter execution deadline`。
- 首次入口在默认沙箱外 Clang ModuleCache 写入时被拒绝（退出1，5.83秒，`Operation not permitted`）；缓存定向后暴露账号池握手断开取消回归（退出1，53.38秒），已修复且定向及最终完整验证通过。未把这些失败计为通过。
- 独立 `swift format lint --strict --recursive Sources Tests Package.swift`：退出0，1.32秒。
- 独立 `python3 scripts/check_docs.py`：退出0，0.05秒；179份 Markdown、本地链接与变更产物检查通过。

## 边界

未执行 Docker/Linux、部署或真实 Desktop 停止验收；由主 Agent 承接。合成成功不代表提供者一定在10秒内返回可信终态；缺失终态仍保留 unknown。
